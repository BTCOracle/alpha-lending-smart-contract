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
   */
  struct Pool {
    // pool status
    PoolStatus status;
    // al token of the pool
    AlToken alToken;
    // pool configuration contract
    IPoolConfiguration poolConfig;
    // total borrow amount on this pool
    uint256 totalBorrows;
    // total share on this pool
    uint256 totalBorrowShares;
    // reserve amount on this pool
    uint256 poolReserves;
    // last update timestamp of this pool
    uint256 lastUpdateTimestamp;
    // total alpha token reward on this pool
    uint256 totalAlphaTokenReward;
    // alpha reward multiplier of each borrow share
    uint256 alphaMultiplier;
  }

  /**
   * @dev the mapping from the ERC20 token to the pool struct of that ERC20 token
   * token address => pool
   */
  mapping(address => Pool) public pools;

  /**
   * @dev the mapping from user address to the ERC20 token to the user data of
   * that ERC20 token's pool
   * user address => token address => user pool data
   */
  mapping(address => mapping(address => UserPoolData)) public userPoolData;

  /**
   * @dev list of all tokens on the lending pool contract.
   */
  ERC20[] public tokenList;

  /**
   * @dev price oracle of the lending pool contract.
   */
  IPriceOracle priceOracle;

  /**
   * @dev alpha token address contract.
   */
  IAlphaDistributor public override distributor;

  /**
   * @dev AltokenDeployer address
   */
  AlTokenDeployer public alTokenDeployer;
  /**
   * @dev VestingAlpha address
   */
  IVestingAlpha public override vestingAlpha;
  // max purchase percent of each liquidation
  // max purchase shares is 50% of user borrow shares
  uint256 public constant CLOSE_FACTOR = 0.5 * 1e18;
  uint256 public constant EQUILIBRIUM = 0.5 * 1e18;
  uint256 public constant MAX_UTILIZATION_RATE = 1 * 1e18;
  uint256 public reservePercent = 0.05 * 1e18;

  constructor(AlTokenDeployer _alTokenDeployer) public {
    alTokenDeployer = _alTokenDeployer;
  }

  /**
   * @dev update accumulated pool's borrow interest from last update timestamp to now then add to total borrows of that pool.
   * any function that use this modifier will update pool's total borrows before starting the function.
   * @param  _token the ERC20 token of the pool that will update accumulated borrow interest to total borrows
   */
  modifier updatePoolWithInterestsAndTimestamp(ERC20 _token) {
    Pool storage pool = pools[address(_token)];
    uint256 borrowInterestRate = pool.poolConfig.calculateInterestRate(
      pool.totalBorrows,
      getTotalLiquidity(_token)
    );
    uint256 cumulativeBorrowInterest = calculateLinearInterest(
      borrowInterestRate,
      pool.lastUpdateTimestamp,
      block.timestamp
    );

    // update pool
    uint256 previousTotalBorrows = pool.totalBorrows;
    pool.totalBorrows = cumulativeBorrowInterest.wadMul(pool.totalBorrows);
    pool.poolReserves = pool.poolReserves.add(
      pool.totalBorrows.sub(previousTotalBorrows).wadMul(reservePercent)
    );
    pool.lastUpdateTimestamp = block.timestamp;
    emit PoolInterestUpdated(address(_token), cumulativeBorrowInterest, pool.totalBorrows);
    _;
  }

  /**
   * @dev update Alpha reward by call poke on distribution contract.
   */
  modifier updateAlphaReward() {
    if (address(distributor) != address(0)) {
      distributor.poke();
    }
    _;
  }

  /**
   * @dev initialize the ERC20 token pool. only owner can initialize the pool.
   * @param _token the ERC20 token of the pool
   * @param _poolConfig the configuration contract of the pool
   */
  function initPool(ERC20 _token, IPoolConfiguration _poolConfig) external onlyOwner {
    for (uint256 i = 0; i < tokenList.length; i++) {
      require(tokenList[i] != _token, "this pool already exists on lending pool");
    }
    string memory alTokenSymbol = string(abi.encodePacked("al", _token.symbol()));
    string memory alTokenName = string(abi.encodePacked("Al", _token.symbol()));
    AlToken alToken = alTokenDeployer.createNewAlToken(alTokenName, alTokenSymbol, _token);
    Pool memory pool = Pool(
      PoolStatus.INACTIVE,
      alToken,
      _poolConfig,
      0,
      0,
      0,
      block.timestamp,
      0,
      0
    );
    pools[address(_token)] = pool;
    tokenList.push(_token);
    emit PoolInitialized(address(_token), address(alToken), address(_poolConfig));
  }

  /**
   * @dev set pool configuration contract of the pool. only owner can set the pool configuration.
   * @param _token the ERC20 token of the pool that will set the configuration
   * @param _poolConfig the interface of the pool's configuration contract
   */
  function setPoolConfig(ERC20 _token, IPoolConfiguration _poolConfig) external onlyOwner {
    Pool storage pool = pools[address(_token)];
    require(
      address(pool.alToken) != address(0),
      "pool isn't initialized, can't set the pool config"
    );
    pool.poolConfig = _poolConfig;
    emit PoolConfigUpdated(address(_token), address(_poolConfig));
  }

  /**
   * @dev set the status of the lending pool. only owner can set the pool's status
   * @param _token the ERC20 token of the pool
   * @param _status the status of the pool
   */
  function setPoolStatus(ERC20 _token, PoolStatus _status) external onlyOwner {
    Pool storage pool = pools[address(_token)];
    pool.status = _status;
  }

  /**
   * @dev set user uses the ERC20 token as collateral flag
   * @param _token the ERC20 token of the pool
   * @param _useAsCollateral the boolean that represent user use the ERC20 token on the pool as collateral or not
   */
  function setUserUseAsCollateral(ERC20 _token, bool _useAsCollateral) external {
    UserPoolData storage userData = userPoolData[msg.sender][address(_token)];
    userData.disableUseAsCollateral = !_useAsCollateral;
    // only disable as collateral need to check the account health
    if (!_useAsCollateral) {
      require(isAccountHealthy(msg.sender), "can't set use as collateral, account isn't healthy.");
    }
  }

  /**
   * @dev set price oracle of the lending pool. only owner can set the price oracle.
   * @param _oracle the price oracle which will get asset price to the lending pool contract
   */
  function setPriceOracle(IPriceOracle _oracle) external onlyOwner {
    priceOracle = _oracle;
    emit PoolPriceOracleUpdated(address(_oracle));
  }

  /**
   * @dev get the pool of the ERC20 token
   * @param _token the ERC20 token of the pool
   * @return status - the pool's status, alTokenAddress - the pool's alToken, poolConfigAddress - the pool's configuration contract,
   * totalBorrows - the pool's total borrows, totalBorrowShares - the pool's total borrow shares, totalLiquidity - the pool's total liquidity,
   * totalAvailableLiquidity - the pool's total available liquidity, lastUpdateTimestamp - the pool's last update timestamp
   */
  function getPool(ERC20 _token)
    external
    view
    returns (
      PoolStatus status,
      address alTokenAddress,
      address poolConfigAddress,
      uint256 totalBorrows,
      uint256 totalBorrowShares,
      uint256 totalLiquidity,
      uint256 totalAvailableLiquidity,
      uint256 lastUpdateTimestamp
    )
  {
    Pool storage pool = pools[address(_token)];
    alTokenAddress = address(pool.alToken);
    poolConfigAddress = address(pool.poolConfig);
    totalBorrows = pool.totalBorrows;
    totalBorrowShares = pool.totalBorrowShares;
    totalLiquidity = getTotalLiquidity(_token);
    totalAvailableLiquidity = getTotalAvailableLiquidity(_token);
    lastUpdateTimestamp = pool.lastUpdateTimestamp;
    status = pool.status;
  }

  /**
   * @dev get user data of the ERC20 token pool
   * @param _user the address of user that need to get the data
   * @param _token the ERC20 token of the pool that need to get the data of the user
   * @return compoundedLiquidityBalance - the compounded liquidity balance of this user in this ERC20 token pool,
   * compoundedBorrowBalance - the compounded borrow balance of this user in this ERC20 pool,
   * userUsePoolAsCollateral - the boolean flag that the user
   * uses the liquidity in this ERC20 token pool as collateral or not
   */
  function getUserPoolData(address _user, ERC20 _token)
    public
    view
    returns (
      uint256 compoundedLiquidityBalance,
      uint256 compoundedBorrowBalance,
      bool userUsePoolAsCollateral
    )
  {
    compoundedLiquidityBalance = getUserCompoundedLiquidityBalance(_user, _token);
    compoundedBorrowBalance = getUserCompoundedBorrowBalance(_user, _token);
    userUsePoolAsCollateral = !userPoolData[_user][address(_token)].disableUseAsCollateral;
  }

  /**
   * @dev calculate the interest rate which is the part of the annual interest rate on the elapsed time
   * @param _rate an annual interest rate express in WAD
   * @param _fromTimestamp the start timestamp to calculate interest
   * @param _toTimestamp the end timestamp to calculate interest
   * @return the interest rate in between the start timestamp to the end timestamp
   */
  function calculateLinearInterest(
    uint256 _rate,
    uint256 _fromTimestamp,
    uint256 _toTimestamp
  ) internal pure returns (uint256) {
    return
      _rate.wadMul(_toTimestamp.sub(_fromTimestamp)).wadDiv(SECONDS_PER_YEAR).add(WadMath.wad());
  }

  /**
   * @dev get user's compounded borrow balance of the user in the ERC20 token pool
   * @param _user the address of the user
   * @param _token the ERC20 token of the pool that will get the compounded borrow balance
   * @return the compounded borrow balance of the user on the ERC20 token pool
   */
  function getUserCompoundedBorrowBalance(address _user, ERC20 _token)
    public
    view
    returns (uint256)
  {
    uint256 userBorrowShares = userPoolData[_user][address(_token)].borrowShares;
    return calculateRoundUpBorrowAmount(_token, userBorrowShares);
  }

  /**
   * @dev get user's compounded liquidity balance of the user in the ERC20 token pool
   * @param _user the account address of the user
   * @param _token the ERC20 token of the pool that will get the compounded liquidity balance
   * @return the compounded liquidity balance of the user on the ERC20 token pool
   */
  function getUserCompoundedLiquidityBalance(address _user, ERC20 _token)
    public
    view
    returns (uint256)
  {
    Pool storage pool = pools[address(_token)];
    uint256 userLiquidityShares = pool.alToken.balanceOf(_user);
    return calculateRoundDownLiquidityAmount(_token, userLiquidityShares);
  }

  /**
   * @dev get total available liquidity in the ERC20 token pool
   * @param _token the ERC20 token of the pool
   * @return the balance of the ERC20 token in the pool
   */
  function getTotalAvailableLiquidity(ERC20 _token) public view returns (uint256) {
    return _token.balanceOf(address(this));
  }

  /**
   * @dev get total liquidity of the ERC20 token pool
   * @param _token the ERC20 token of the pool
   * @return the total liquidity on the lending pool which is the sum of total borrows and available liquidity
   */
  function getTotalLiquidity(ERC20 _token) public view returns (uint256) {
    Pool storage pool = pools[address(_token)];
    return
      pool.totalBorrows.add(getTotalAvailableLiquidity(_token)).sub(
        pools[address(_token)].poolReserves
      );
  }

  /**
   * @dev calculate liquidity share amount (round-down)
   * @param _token the ERC20 token of the pool
   * @param _amount the amount of liquidity to calculate the liquidity shares
   * @return the amount of liquidity shares which is calculated from the below formula
   * liquidity shares = (_amount * total liquidity shares) / total liquidity
   * if the calculated liquidity shares = 2.9 then liquidity shares will be 2
   */
  function calculateRoundDownLiquidityShareAmount(ERC20 _token, uint256 _amount)
    internal
    view
    returns (uint256)
  {
    Pool storage pool = pools[address(_token)];
    uint256 totalLiquidity = getTotalLiquidity(_token);
    uint256 totalLiquidityShares = pool.alToken.totalSupply();
    if (totalLiquidity == 0 && totalLiquidityShares == 0) {
      return _amount;
    }
    return _amount.mul(totalLiquidityShares).div(totalLiquidity);
  }

  /**
   * @dev calculate borrow share amount (round-up)
   * @param _token the ERC20 token of the pool
   * @param _amount the amount of borrow to calculate the borrow shares
   * @return the borrow amount which is calculated from the below formula
   * borrow shares = ((amount * total borrow shares) + (total borrows -  1)) / total borrow
   * if the calculated borrow shares = 10.1 then the borrow shares = 11
   */
  function calculateRoundUpBorrowShareAmount(ERC20 _token, uint256 _amount)
    internal
    view
    returns (uint256)
  {
    Pool storage pool = pools[address(_token)];
    // borrow share amount of the first borrowing is equal to amount
    if (pool.totalBorrows == 0 || pool.totalBorrowShares == 0) {
      return _amount;
    }
    return _amount.mul(pool.totalBorrowShares).divCeil(pool.totalBorrows);
  }

  /**
   * @dev calculate borrow share amount (round-down)
   * @param _token the ERC20 token of the pool
   * @param _amount the amount of borrow to calculate the borrow shares
   * @return the borrow amount which is calculated from the below formula
   * borrow shares = (_amount * total borrow shares) / total borrows
   * if the calculated borrow shares = 10.9 then the borrow shares = 10
   */
  function calculateRoundDownBorrowShareAmount(ERC20 _token, uint256 _amount)
    internal
    view
    returns (uint256)
  {
    Pool storage pool = pools[address(_token)];
    if (pool.totalBorrowShares == 0) {
      return 0;
    }
    return _amount.mul(pool.totalBorrowShares).div(pool.totalBorrows);
  }

  /**
   * @dev calculate liquidity share amount (round-up)
   * @param _token the ERC20 token of the pool
   * @param _amount the amount of liquidity to calculate the liquidity shares
   * @return the liquidity shares which is calculated from the below formula
   * liquidity shares = ((amount * total liquidity shares) + (total liquidity - 1)) / total liquidity shares
   * if the calculated liquidity shares = 10.1 then the liquidity shares = 11
   */
  function calculateRoundUpLiquidityShareAmount(ERC20 _token, uint256 _amount)
    internal
    view
    returns (uint256)
  {
    Pool storage pool = pools[address(_token)];
    uint256 poolTotalLiquidityShares = pool.alToken.totalSupply();
    uint256 poolTotalLiquidity = getTotalLiquidity(_token);
    // liquidity share amount of the first depositing is equal to amount
    if (poolTotalLiquidity == 0 || poolTotalLiquidityShares == 0) {
      return _amount;
    }
    return _amount.mul(poolTotalLiquidityShares).divCeil(poolTotalLiquidity);
  }

  /**
   * @dev calculate liquidity amount (round-down)
   * @param _token the ERC20 token of the pool
   * @param _shareAmount the liquidity shares to calculate the amount of liquidity
   * @return the amount of liquidity which is calculated from the below formula
   * liquidity amount = (_shareAmount * total liquidity) / total liquidity shares
   * if the calculated liquidity amount = 10.9 then the liquidity amount = 10
   */
  function calculateRoundDownLiquidityAmount(ERC20 _token, uint256 _shareAmount)
    internal
    view
    returns (uint256)
  {
    Pool storage pool = pools[address(_token)];
    uint256 poolTotalLiquidityShares = pool.alToken.totalSupply();
    if (poolTotalLiquidityShares == 0) {
      return 0;
    }
    return _shareAmount.mul(getTotalLiquidity(_token)).div(poolTotalLiquidityShares);
  }

  /**
   * @dev calculate borrow amount (round-up)
   * @param _token the ERC20 token of the pool
   * @param _shareAmount the borrow shares to calculate the amount of borrow
