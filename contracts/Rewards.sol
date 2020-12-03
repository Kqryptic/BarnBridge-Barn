// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.7.1;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IBarn.sol";
import "hardhat/console.sol";

contract Rewards is Ownable {
    using SafeMath for uint256;

    address public pullTokenFrom;
    uint256 public pullStartAt;
    uint256 public pullEndAt;
    uint256 public pullDuration; // == pullEndAt - pullStartAt
    uint256 public pullTotalAmount;
    uint256 public lastPullTs;
    uint256 constant decimals = 10 ** 18;

    uint256 public balanceBefore;
    uint256 public currentMultiplier;

    mapping(address => uint256) public userMultiplier;
    mapping(address => uint256) public owed;

    IBarn public barn;
    IERC20 public token;

    event Claim(address indexed user, uint256 amount);

    constructor(address _owner, address _token, address _barn) {
        transferOwnership(_owner);

        token = IERC20(_token);
        barn = IBarn(_barn);
    }

    // registerUserAction is called by the Barn every time the user does a deposit or withdrawal in order to
    // account for the changes in reward that the user should get
    // it updates the amount owed to the user without transferring the funds
    function registerUserAction(address user) public {
        require(msg.sender == address(barn), 'only callable by barn');

        _calculateOwed(user);
    }

    // claim calculates the currently owed reward and transfers the funds to the user
    function claim() public {
        _calculateOwed(msg.sender);

        uint256 amount = owed[msg.sender];
        require(amount > 0, "nothing to claim");

        owed[msg.sender] = 0;

        token.transfer(msg.sender, amount);

        emit Claim(msg.sender, amount);
    }

    // ackFunds checks the difference between the last known balance of `token` and the current one
    // if it goes up, the multiplier is re-calculated
    // if it goes down, it only updates the known balance
    function ackFunds() public {
        uint256 balanceNow = token.balanceOf(address(this));

        if (balanceNow == 0 || balanceNow <= balanceBefore) {
            balanceBefore = balanceNow;
            return;
        }

        uint256 totalStakedBond = barn.bondStaked();
        // if there's no bond staked, it doesn't make sense to ackFunds because there's nobody to distribute them to
        // and the calculation would fail anyways due to division by 0
        if (totalStakedBond == 0) {
            return;
        }

        uint256 diff = balanceNow.sub(balanceBefore);
        uint256 multiplier = currentMultiplier.add(diff.mul(decimals).div(totalStakedBond));

        balanceBefore = balanceNow;
        currentMultiplier = multiplier;
    }

    // setupPullToken is used to setup the rewards system; only callable by contract owner
    // set source to address(0) to disable the functionality
    function setupPullToken(address source, uint256 startAt, uint256 endAt, uint256 amount) public {
        require(msg.sender == owner(), '!owner');

        pullTokenFrom = source;
        pullStartAt = startAt;
        pullEndAt = endAt;
        pullDuration = endAt.sub(startAt);
        pullTotalAmount = amount;
        lastPullTs = startAt;
    }

    // setBarn sets the address of the BarnBridge Barn into the state variable
    function setBarn(address _barn) public {
        require(msg.sender == owner(), '!owner');

        barn = IBarn(_barn);
    }

    // userClaimableReward returns the total amount of `token` that the user can claim at the
    function userClaimableReward(address user) public view returns (uint256) {
        return owed[user].add(_userPendingReward(user));
    }

    // _pullToken calculates the amount based on the time passed since the last pull relative
    // to the total amount of time that the pull functionality is active and executes a transferFrom from the
    // address supplied as `pullTokenFrom`, if enabled
    function _pullToken() internal {
        if (
            pullTokenFrom == address(0) ||
            block.timestamp < pullStartAt
        ) {
            return;
        }

        uint256 timestampCap = pullEndAt;
        if (block.timestamp < pullEndAt) {
            timestampCap = block.timestamp;
        }

        if (lastPullTs >= timestampCap) {
            return;
        }

        uint256 timeSinceLastPull = timestampCap.sub(lastPullTs);
        uint256 shareToPull = timeSinceLastPull.mul(decimals).div(pullDuration);
        uint256 amountToPull = pullTotalAmount.mul(shareToPull).div(decimals);

        token.transferFrom(pullTokenFrom, address(this), amountToPull);
        lastPullTs = block.timestamp;
    }

    // _calculateOwed calculates and updates the total amount that is owed to an user and updates the user's multiplier
    // to the current value
    // it automatically attempts to pull the token from the source and acknowledge the funds
    function _calculateOwed(address user) internal {
        _pullToken();
        ackFunds();

        uint256 reward = _userPendingReward(user);

        owed[user] = owed[user].add(reward);
        userMultiplier[user] = currentMultiplier;
    }

    // _userPendingReward calculates the reward that should be based on the current multiplier / anything that's not included in the `owed[user]` value
    // it does not represent the entire reward that's due to the user unless added on top of `owed[user]`
    function _userPendingReward(address user) internal view returns (uint256) {
        uint256 multiplier = currentMultiplier.sub(userMultiplier[user]);

        return barn.balanceOf(user).mul(multiplier).div(decimals);
    }
}
