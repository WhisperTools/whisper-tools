// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;
pragma abicoder v2;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";

interface IMuteSwitchFactoryDynamic {
    event PairCreated(
        address indexed token0,
        address indexed token1,
        address pair,
        uint
    );

    function feeTo() external view returns (address);

    function protocolFeeFixed() external view returns (uint256);

    function protocolFeeDynamic() external view returns (uint256);

    function getPair(
        address tokenA,
        address tokenB,
        bool stable
    ) external view returns (address pair);

    function allPairs(uint) external view returns (address pair);

    function allPairsLength() external view returns (uint);

    function createPair(
        address tokenA,
        address tokenB,
        uint feeType,
        bool stable
    ) external returns (address pair);

    function setFeeTo(address) external;

    function pairCodeHash() external pure returns (bytes32);
}

interface IMuteSwitchPairDynamic {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external pure returns (string memory);

    function symbol() external pure returns (string memory);

    function decimals() external pure returns (uint8);

    function totalSupply() external view returns (uint);

    function stable() external pure returns (bool);

    function balanceOf(address owner) external view returns (uint);

    function allowance(
        address owner,
        address spender
    ) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);

    function transfer(address to, uint value) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint value
    ) external returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);

    function PERMIT_TYPEHASH() external pure returns (bytes32);

    function nonces(address owner) external view returns (uint);

    function permit(
        address owner,
        address spender,
        uint value,
        uint deadline,
        bytes memory sig
    ) external;

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(
        address indexed sender,
        uint amount0,
        uint amount1,
        address indexed to
    );
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    function MINIMUM_LIQUIDITY() external pure returns (uint);

    function factory() external view returns (address);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function price0CumulativeLast() external view returns (uint);

    function price1CumulativeLast() external view returns (uint);

    function kLast() external view returns (uint);

    function pairFee() external view returns (uint);

    function mint(address to) external returns (uint liquidity);

    function burn(address to) external returns (uint amount0, uint amount1);

    function swap(
        uint amount0Out,
        uint amount1Out,
        address to,
        bytes calldata data
    ) external;

    function skim(address to) external;

    function sync() external;

    function claimFees() external returns (uint claimed0, uint claimed1);

    function claimFeesView(
        address recipient
    ) external view returns (uint claimed0, uint claimed1);

    function initialize(address, address, uint, bool) external;

    function getAmountOut(uint, address) external view returns (uint);
}

contract Locker is Ownable, ReentrancyGuard, Pausable {
    using Address for address;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address payable feeReceiver =
        payable(0xaCE5005f3E960A8e9Bfbe95f0fa6C925858a7272);

    uint256 lockFee = 0.05 ether;

    struct LockParams {
        uint256 amount;
        address token;
        address owner;
        uint64 unlockTime;
        uint64 lockTime;
        uint16 firstPercent;
        uint64 vestingPeriod;
        uint16 amountPerCycle;
        string title;
        bool isLP;
        uint64 id;
        uint64 lastUpdatedTime;
        uint256 claimed;
    }

    LockParams[] public locks;
    mapping(address => uint64[]) public userLocks;
    uint256 constant MAX_USER_LOCK = 100;

    mapping(address => bool) private listFreeTokens;

    modifier onlyContract(address account) {
        require(
            account.isContract(),
            "The address does not contain a contract"
        );
        _;
    }

    event LockAdded(
        uint256 indexed id,
        address token,
        address owner,
        uint256 amount,
        uint256 unlockDate
    );
    event LockUpdated(
        uint256 indexed id,
        address token,
        address owner,
        uint256 newAmount,
        uint256 newUnlockDate
    );
    event LockRemoved(
        uint256 indexed id,
        address token,
        address owner,
        uint256 amount,
        uint256 unlockedAt
    );
    event LockDescriptionChanged(uint256 lockId);
    event LockOwnerChanged(uint256 lockId, address owner, address newOwner);
    event LockOwnerRenounced(uint256 lockId);

    constructor() {
        listFreeTokens[0xc8Ec5B0627C794de0e4ea5d97AD9A556B361d243] = true; // WISP
        listFreeTokens[0xBe21BCD3a21dC4Dd6C58945f0F5DE4132644020a] = true; // vMLP (WETH/WISP)
    }

    receive() external payable {}

    fallback() external payable {}

    function lock(
        LockParams memory _params
    ) external payable whenNotPaused nonReentrant {
        LockParams memory params = _params;
        require(params.firstPercent <= 10000, "invalid first percent");
        require(params.amountPerCycle <= 10000, "invalid cycle percent");
        require(params.unlockTime > block.timestamp, "invalid unlock time");
        require(
            params.firstPercent > 0,
            "first percent must be positive number"
        );
        require(
            params.vestingPeriod > 0,
            "vesting period must be positive number"
        );
        require(
            params.amountPerCycle > 0,
            "cycle percent must be positive number"
        );

        _chargeFees(params.token);

        uint256 beforeBalance = IERC20(params.token).balanceOf(address(this));
        IERC20(params.token).safeTransferFrom(
            msg.sender,
            address(this),
            params.amount
        );
        uint256 balance = IERC20(params.token).balanceOf(address(this));
        require(
            beforeBalance + params.amount <= balance,
            "should exclude from fee this address"
        );
        if (params.isLP) {
            _getFactoryAddress(params.token);
        }

        params.id = uint64(locks.length);
        params.lastUpdatedTime = uint64(block.timestamp);
        params.lockTime = uint64(block.timestamp);
        params.claimed = 0;
        locks.push(params);
        userLocks[params.owner].push(params.id);
        require(
            userLocks[params.owner].length <= MAX_USER_LOCK,
            "can't create lock more than limit"
        );

        emit LockAdded(
            params.id,
            params.token,
            params.owner,
            params.amount,
            params.unlockTime
        );
    }

    function unlock(uint64 id) external nonReentrant {
        LockParams storage currentLock = locks[id];
        require(msg.sender == currentLock.owner, "caller is not lock a owner");
        require(
            block.timestamp >= currentLock.unlockTime,
            "can't unlock before unlockTime"
        );
        uint64 vested = currentLock.firstPercent;
        if (vested < 10000)
            vested =
                vested +
                uint64(
                    (block.timestamp - currentLock.unlockTime)
                        .div(uint256(currentLock.vestingPeriod))
                        .mul(uint256(currentLock.amountPerCycle))
                );
        if (vested > 10000) vested = 10000;
        if (vested > 0) {
            uint256 vestedAmount = currentLock.amount.mul(uint256(vested)).div(
                10000
            );
            uint256 releaseAmount = vestedAmount.sub(currentLock.claimed);
            currentLock.claimed = currentLock.claimed + releaseAmount;
            IERC20(currentLock.token).safeTransfer(
                currentLock.owner,
                releaseAmount
            );
        }

        if (currentLock.isLP) {
            _claimLPFeesAndSend(currentLock.token, currentLock.owner);
        }
        currentLock.lastUpdatedTime = uint64(block.timestamp);

        emit LockRemoved(
            currentLock.id,
            currentLock.token,
            currentLock.owner,
            currentLock.amount,
            currentLock.lastUpdatedTime
        );
    }

    function renounceOwnershipOfLock(uint64 id) external {
        LockParams storage currentLock = locks[id];
        uint64[] storage userLock = userLocks[msg.sender];
        require(msg.sender == currentLock.owner, "caller is not owner of lock");
        currentLock.owner = address(0);
        for (uint256 index = 0; index < userLock.length; index++) {
            if (userLock[index] == id) {
                userLock[index] = userLock[userLock.length - 1];
                break;
            }
        }
        userLock.pop();

        emit LockOwnerRenounced(currentLock.id);
    }

    function updateLockOwnership(uint64 id, address newOwner) external {
        LockParams storage currentLock = locks[id];
        address oldOwner = currentLock.owner;
        uint64[] storage oldOwnerUserLock = userLocks[msg.sender];
        require(msg.sender == currentLock.owner, "caller is not owner of lock");

        currentLock.owner = newOwner;
        userLocks[currentLock.owner].push(currentLock.id);
        require(
            userLocks[currentLock.owner].length <= MAX_USER_LOCK,
            "can't create lock more than limit"
        );

        for (uint256 index = 0; index < oldOwnerUserLock.length; index++) {
            if (oldOwnerUserLock[index] == id) {
                oldOwnerUserLock[index] = oldOwnerUserLock[
                    oldOwnerUserLock.length - 1
                ];
                break;
            }
        }
        oldOwnerUserLock.pop();

        emit LockOwnerChanged(currentLock.id, oldOwner, currentLock.owner);
    }

    function updateLockTitle(uint64 id, string memory _title) external {
        LockParams storage currentLock = locks[id];
        require(msg.sender == currentLock.owner, "caller is not owner of lock");
        currentLock.title = _title;

        emit LockDescriptionChanged(currentLock.id);
    }

    function updateLockInfo(
        uint64 id,
        uint256 _amount,
        uint64 _unlockTime
    ) external nonReentrant {
        LockParams storage currentLock = locks[id];
        require(msg.sender == currentLock.owner, "caller is not owner of lock");
        require(
            _amount >= currentLock.amount,
            "new amount should be bigger or equal than previous amount"
        );
        require(
            _unlockTime >= currentLock.unlockTime,
            "new unlock time should be after or equal than previous one"
        );
        uint256 amount = _amount - currentLock.amount;
        currentLock.amount = _amount;
        currentLock.unlockTime = _unlockTime;
        uint256 beforeBalance = IERC20(currentLock.token).balanceOf(
            address(this)
        );
        IERC20(currentLock.token).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );
        uint256 balance = IERC20(currentLock.token).balanceOf(address(this));
        require(
            beforeBalance + amount <= balance,
            "should exclude from fee this address"
        );

        emit LockUpdated(
            currentLock.id,
            currentLock.token,
            currentLock.owner,
            currentLock.amount,
            currentLock.unlockTime
        );
    }

    function _claimLPFeesAndSend(
        address token,
        address lpFeeReceiver
    ) internal {
        IMuteSwitchPairDynamic pair = IMuteSwitchPairDynamic(
            _getLPAddress(token, _getFactoryAddress(token))
        );
        try pair.claimFees() returns (uint claimed0, uint claimed1) {
            IERC20(pair.token0()).safeTransfer(lpFeeReceiver, claimed0);
            IERC20(pair.token1()).safeTransfer(lpFeeReceiver, claimed1);
        } catch {}
    }

    function getLocksLength(bool isLP) public view returns (uint256 count) {
        count = 0;
        for (uint256 index = 0; index < locks.length; index++) {
            if (locks[index].isLP == isLP) count++;
        }
    }

    function getLocks(
        bool isLP,
        uint256 size,
        uint256 cursor
    ) external view returns (LockParams[] memory) {
        uint256 length = size;
        uint256 temp = getLocksLength(isLP);

        if (length > temp - cursor) {
            length = temp - cursor;
        }

        LockParams[] memory branch = new LockParams[](length);
        uint256 count = 0;
        for (uint256 i = 0; i < locks.length; i++) {
            if (locks[i].isLP == isLP) {
                count++;
                if (count > cursor + length) break;
                if (count > cursor) branch[count - cursor - 1] = locks[i];
            }
        }

        return branch;
    }

    function getUserLocksLength(
        bool isLP,
        address _user
    ) public view returns (uint256 count) {
        count = 0;
        for (uint256 index = 0; index < userLocks[_user].length; index++) {
            if (
                locks[userLocks[_user][index]].isLP == isLP &&
                locks[userLocks[_user][index]].amount !=
                locks[userLocks[_user][index]].claimed
            ) count++;
        }
    }

    function getUserLocks(
        bool isLP,
        address _user,
        uint256 size,
        uint256 cursor
    ) external view returns (LockParams[] memory) {
        uint256 length = size;
        uint256 temp = getUserLocksLength(isLP, _user);

        if (length > temp - cursor) {
            length = temp - cursor;
        }

        LockParams[] memory branch = new LockParams[](length);
        uint256 count = 0;

        for (uint256 i = 0; i < userLocks[_user].length; i++) {
            if (locks[userLocks[_user][i]].isLP == isLP) {
                count++;
                if (count > cursor + length) break;
                if (count > cursor)
                    branch[count - cursor - 1] = locks[userLocks[_user][i]];
            }
        }

        return branch;
    }

    function searchByAddress(
        address token
    ) external view returns (LockParams[] memory) {
        LockParams[] memory temp = new LockParams[](1000);
        uint256 count = 0;
        for (uint256 index = 0; index < locks.length; index++) {
            if (locks[index].token == token) {
                temp[count] = locks[index];
                count++;
            }
        }
        LockParams[] memory branch = new LockParams[](count);
        for (uint256 index = 0; index < count; index++) {
            branch[index] = temp[index];
        }
        return branch;
    }

    function _getFactoryAddress(address token) internal view returns (address) {
        address possibleFactoryAddress;
        try IUniswapV2Pair(token).factory() returns (address factory) {
            possibleFactoryAddress = factory;
        } catch {
            revert("this token is not a LP token");
        }
        require(
            possibleFactoryAddress != address(0) &&
                _isValidLpToken(token, possibleFactoryAddress),
            "this token is not a LP token."
        );
        return possibleFactoryAddress;
    }

    function _isValidLpToken(
        address token,
        address factory
    ) internal view returns (bool) {
        return _getLPAddress(token, factory) == token;
    }

    function _getLPAddress(
        address token,
        address factory
    ) internal view returns (address) {
        IUniswapV2Pair pair = IUniswapV2Pair(token);
        address possibleFactoryPair;
        try
            IUniswapV2Factory(factory).getPair(pair.token0(), pair.token1())
        returns (address factoryPair) {
            possibleFactoryPair = factoryPair;
        } catch {
            try
                IMuteSwitchFactoryDynamic(factory).getPair(
                    pair.token0(),
                    pair.token1(),
                    true
                )
            returns (address factoryPairStable) {
                if (factoryPairStable == address(0)) {
                    try
                        IMuteSwitchFactoryDynamic(factory).getPair(
                            pair.token0(),
                            pair.token1(),
                            false
                        )
                    returns (address factoryPairNonStable) {
                        possibleFactoryPair = factoryPairNonStable;
                    } catch {
                        revert("this token is not a LP token");
                    }
                } else {
                    possibleFactoryPair = factoryPairStable;
                }
            } catch {
                revert("this token is not a LP token");
            }
        }
        return possibleFactoryPair;
    }

    function _chargeFees(address _tokenAddress) internal {
        uint256 minRequiredFeeInEth = getFeesInETH(_tokenAddress);
        if (minRequiredFeeInEth > 0) {
            bool feesBelowMinRequired = msg.value < minRequiredFeeInEth;
            uint256 feeDiff = feesBelowMinRequired
                ? SafeMath.sub(minRequiredFeeInEth, msg.value)
                : SafeMath.sub(msg.value, minRequiredFeeInEth);

            if (feesBelowMinRequired) {
                uint256 feeSlippagePercentage = feeDiff.mul(100).div(
                    minRequiredFeeInEth
                );
                //will allow if diff is less than 5%
                require(feeSlippagePercentage <= 5, "Fee not met");
            }
            (bool success, ) = feeReceiver.call{
                value: feesBelowMinRequired ? msg.value : minRequiredFeeInEth
            }("");
            require(success, "Fee transfer failed");
            bool refundSuccess;
            /* refund difference. */
            if (!feesBelowMinRequired && feeDiff > 0) {
                (refundSuccess, ) = _msgSender().call{value: feeDiff}("");
            }
        }
    }

    function getFeesInETH(address _tokenAddress) public view returns (uint256) {
        //token listed free or fee params not set
        if (isFreeToken(_tokenAddress)) {
            return 0;
        } else {
            return lockFee;
        }
    }

    function isFreeToken(address token) public view returns (bool) {
        return listFreeTokens[token];
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setLockFee(uint256 _lockFee) external onlyOwner {
        require(_lockFee >= 0, "fees should be greater or equal 0");
        lockFee = _lockFee;
    }

    function setFeeReceiver(address payable _feeReceiver) external onlyOwner {
        require(_feeReceiver != address(0), "Invalid wallet address");
        feeReceiver = _feeReceiver;
    }

    function addTokenToFreeList(
        address token
    ) external onlyOwner onlyContract(token) {
        listFreeTokens[token] = true;
    }

    function removeTokenFromFreeList(
        address token
    ) external onlyOwner onlyContract(token) {
        listFreeTokens[token] = false;
    }

    function emergencyOperate(
        address[] calldata target,
        uint256[] calldata values,
        bytes[] calldata data
    ) external onlyOwner returns (bool success, bytes memory returndata) {
        for (uint256 index = 0; index < target.length; index++) {
            (success, returndata) = target[index].call{value: values[index]}(
                data[index]
            );
        }
    }

    function withdrawStuckETH() external onlyOwner {
        bool success;
        (success, ) = address(msg.sender).call{value: address(this).balance}(
            ""
        );
    }
}
