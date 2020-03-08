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
