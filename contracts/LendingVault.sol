pragma solidity 0.6.11;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IAlphaDistributor.sol";
import "./interfaces/IAlphaReceiver.sol";
import "./interfaces/ILendingPool.sol";
import "./interfaces/IPoolConfiguration.sol";
import "./interfaces/IPriceOracle.sol";
import "./interfaces/IVestingAlpha.sol";
import "./AlToken.sol";
import "./AlTokenDeployer.sol";
import "./libraries/WadMath.sol";
import "./libraries/Math.sol";

/**
 * @title Lending pool contract
 * @notice Implements the core contract of lending pool.
 * this contract manages all states and handles user interaction with the pool.
 * @author Alpha
 **/

contract LendingPool is Ownable, ILendingPool, IAlphaReceiver, ReentrancyGuard {
  using SafeMath for uint256;
  using WadMath for uint256;
  using Math for uint256;
  using SafeERC20 for ERC20;

  /*
   * Lending pool smart contracts
   * -----------------------------
   * Each ERC20 token has an individual pool which users provide their liquidity to the pool.
   * Users can use their liquidity as collateral to borrow any asset from all pools if their account is still healthy.
   * By account health checking, the total borrow value must less than the total collateral value (collateral value is
   * ~75% of the liquidity value depends on each token). Borrower need to repay the loan with accumulated interest.
   * Liquidity provider would receive the borrow interest. In case of the user account is not healthy
   * then liquidator can help to liquidate the user's account then receive the collateral with liquidation bonus as the reward.
   *
   * The status of the pool
   * -----------------------------
   * The pool has 3 status. every pool will have only one status at a time.
   * 1. INACTIVE - the pool is on initialized state or inactive state so it's not ready for user to do any actions. users can't deposit, borrow,
   * repay and withdraw
   * 2 .ACTIVE - the pool is active. users can deposit, borrow, repay, withdraw and liquidate
   * 3. CLOSED - the pool is waiting for inactive state. users can clear their account by repaying, withdrawal, liquidation but can't deposit, borrow
   */
  enum PoolStatus {INACTIVE, ACTIVE, CLOSED}
  uint256 internal constant SECONDS_PER_YEAR = 365 days;
  /**
   * @dev emitted on initilize pool
   * @param pool the address of the ERC20 token of the pool
   * @param alTokenAddress the address of the pool's alToken
   * @param poolConfigAddress the address of the pool's configuration contract
   */
  event PoolInitialized(
    address indexed pool,
    address indexed alTokenAddress,
    address indexed poolConfigAddress
  );

  /**
   * @dev emitted on update pool configuration
   * @param pool the address of the ERC20 token of the pool
   * @param poolConfigAddress the address of the updated pool's configuration contract
   */
  event PoolConfigUpdated(address indexed pool, address poolConfigAddress);

  /**
   * @dev emitted on set price oracle
   * @param priceOracleAddress the address of the price oracle
   */
  event PoolPriceOracleUpdated(address indexed priceOracleAddress);

  /**
   * @dev emitted on pool updates interest
   * @param pool the address of the ERC20 token of the pool
   * @param cumulativeBorrowInterest the borrow interest which accumulated from last update timestamp to now
   * @param totalBorrows the updated total borrows of the pool. increasing by the cumulative borrow interest.
   */
  event PoolInterestUpdated(
    address indexed pool,
    uint256 cumulativeBorrowInterest,
    uint256 totalBorrows
  );

  /**
   * @dev emitted on deposit
   * @param pool the address of the ERC20 token of the pool
   * @param user the address of the user who deposit the ERC20 token to the pool
   * @param depositShares the share amount of the ERC20 token which calculated from deposit amount
   * Note: depositShares is the same as number of alphaToken
   * @param depositAmount the amount of the ERC20 that deposit to the pool
   */
  event Deposit(
    address indexed pool,
    address indexed user,
    uint256 depositShares,
    uint256 depositAmount
  );

  /**
   * @dev emitted on borrow
   * @param pool the address of the ERC20 token of the pool
   * @param user the address of the user who borrow the ERC20 token from the pool
   * @param borrowShares the amount of borrow shares which calculated from borrow amount
   * @param borrowAmount the amount of borrow
   */
  event Borrow(
    address indexed pool,
    address indexed user,
    uint256 borrowShares,
    uint256 borrowAmount
  );

  /**
   * @dev emitted on repay
   * @param pool the address of the ERC20 token of the pool
   * @param user the address of the user who repay the ERC20 token to the pool
   * @param repayShares the amount of repay shares which calculated from repay amount
   * @param repayAmount the amount of repay
   */
  event Repay(address indexed pool, address indexed user, uint256 repayShares, uint256 repayAmount);

  /**
   * @dev emitted on withdraw alToken
   * @param pool the address of the ERC20 token of the pool
   * @param user the address of the user who withdraw the ERC20 token from the pool
   * @param withdrawShares the amount of withdraw shares which calculated from withdraw amount
   * @param withdrawAmount the amount of withdraw
   */
  event Withdraw(
    address indexed pool,
    address indexed user,
    uint256 withdrawShares,
    uint256 withdrawAmount
  );

  /**
   * @dev emitted on liquidate
   * @param user the address of the user who is liquidated by liquidator
   * @param pool the address of the ERC20 token which is liquidated by liquidator
   * @param collateral the address of the ERC20 token that liquidator received as a rewards
   * @param liquidateAmount the amount of the ERC20 token that liquidator liquidate for the user
   * @param liquidateShares the amount of liquidate shares which calculated from liquidate amount
   * @param collateralAmount the amount of the collateral which calculated from liquidate amount that liquidator want to liquidate
   * @param collateralShares the amount of collateral shares which liquidator received from liquidation in from of alToken
   * @param liquidator the address of the liquidator
   */
  event Liquidate(
    address indexed user,
    address pool,
    address collateral,
    uint256 liquidateAmount,
    uint256 liquidateShares,
    uint256 collateralAmount,
    uint256 collateralShares,
    address liquidator
  );

  /**
   * @dev emitted on reserve withdraw
   * @param pool the address of the ERC20 token of the pool
   * @param amount the amount to withdraw
   * @param withdrawer the address of withdrawer
   */
  event ReserveWithdrawn(address indexed pool, uint256 amount, address withdrawer);

  /**
   * @dev emitted on update reserve percent
   * @param previousReservePercent the previous pool's reserve percent
   * @param newReservePercent the updated pool's reserve percent
   */
  event ReservePercentUpdated(uint256 previousReservePercent, uint256 newReservePercent);

  /**
   * @dev the struct for storing the user's state separately on each pool
   */
  struct UserPoolData {
    // the user set to used this pool as collateral for borrowing
    bool disableUseAsCollateral;
    // borrow shares of the user of this pool. If user didn't borrow this pool then shere will be 0
    uint256 borrowShares;
    // latest alpha multiplier (borrow reward multiplier) of the user of this pool. Using to calculate current borrow reward.
    uint256 latestAlphaMultiplier;
  }

  /**
   * @dev the struct for storing the pool's state separately on each ERC20 token
