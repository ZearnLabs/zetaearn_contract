// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "./interfaces/IValidatorOperator.sol";
import "./interfaces/IStZETA.sol";


contract ValidatorOperator is
    IValidatorOperator,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    /// @notice all roles.
    bytes32 public constant DAO_ROLE = keccak256("ZETAEARN_DAO");
    bytes32 public constant ORACLE_ROLE = keccak256("ZETAEARN_ORACLE");
    bytes32 public constant PAUSE_ROLE = keccak256("ZETAEARN_PAUSE_OPERATOR");
    bytes32 public constant UNPAUSE_ROLE = keccak256("ZETAEARN_UNPAUSE_OPERATOR");

    /// @notice contract version.
    string public version;

    /// @notice node operator ratio
    uint256 public ratio;

    /// @notice node operator status
    NodeOperatorRegistryStatus public status;
    
    /// @notice dao address.
    address public override dao;

    /// @notice oracle address.
    address public override oracle;

    /// @notice stZETA address.
    address public override stZETA;

    /// @notice validator operator delegate address
    address public override delegateAddress;

    /// @notice validator operator reward address
    address public override rewardAddress;

    /// @notice validator operator total stake amount
    uint256 public override totalStake;

    /// @notice validator operator commission rate, max is 10000, 100%, need divide 100
    uint16 public override commissionRate;

    // -------------------------------------
    // after staking slot
    // -------------------------------------
    
    /// @notice record unbond nonce
    mapping(address => uint256) public unbondNonces;

    // it is mapping, first key is address, second key is unbondNonce, value is DelegatorUnbond
    // DelegateUnbond a data structure, include shares and withdrawEpoch
    mapping(address => mapping(uint256 => DelegatorUnbond)) public unbonds_new;

    /// @notice record epoch unbond nonces. NOT USE NOW
    mapping(uint256 => uint256[]) public unbondEpochsNonces;

    /// @notice record epoch finished unbond nonces. NOT USE NOW.
    mapping(uint256 => uint256[]) public finishedUnbondEpochsNonces;

    /// @notice finished unbond epoch received amount
    mapping (uint256 => uint256) public finishedUnbondEpochAmount;

    /// @notice total unbond epoch amount
    uint256 public override totalUnbondAmount;

    /// @notice last epoch finished unbond
    uint256 public override lastEpochFinishedUnbond;

    ////////////////////////////////////////////////////////////
    /////                                                    ///
    /////                   Functions                        ///
    /////                                                    ///
    ////////////////////////////////////////////////////////////

    /// @notice only stZETA can call
    modifier isStZETA() {
        require(msg.sender == stZETA, "not stZETA");
        _;
    }

    /// @notice init ValidatorOperator contract
    /// @param _dao dao address
    /// @param _oracle oracle address
    /// @param _stZETA stZETA address
    /// @param _delegateAddress validator operator delegation address
    /// @param _rewardAddress validator operator reward address
    /// @param _commissionRate validator operator commission rate
    function initialize(
        address _dao,
        address _oracle,
        address _stZETA,
        address _delegateAddress,
        address _rewardAddress,
        uint16 _commissionRate
    ) external override initializer {
        __Pausable_init_unchained();
        __AccessControl_init_unchained();
        __ReentrancyGuard_init_unchained();

        // set role
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSE_ROLE, msg.sender);
        _grantRole(UNPAUSE_ROLE, _dao);
        _grantRole(DAO_ROLE, _dao);
        _grantRole(ORACLE_ROLE, _oracle);

        // set address
        dao = _dao;
        oracle = _oracle;
        stZETA = _stZETA;
        delegateAddress = _delegateAddress;
        rewardAddress = _rewardAddress;

        // set commission
        commissionRate = _commissionRate;
        // set 10**10, easy to calculate
        ratio = 10**10;
        status = NodeOperatorRegistryStatus.ACTIVE;

        version = "1.0.2";
    }

    /// @notice when node quit, wait oracle withdraw all stake and reward
    function withdrawTotalDelegated() external override isStZETA {
        // it is only a flag, in the future, we can use other way to mark it
        status = NodeOperatorRegistryStatus.WITHDRAWTOTAL;

        emit WithdrawTotalDelegated();
    }

    /// @notice to delegate
    function delegate() external payable override isStZETA {
        // to delegate
        (bool success, ) = payable(rewardAddress).call{value: msg.value}("");
        // check delegate success
        require(success, "delegate failed");
        // update total stake
        totalStake += msg.value;

        emit Delegate(msg.value, rewardAddress, totalStake);
    }

    /// @notice to claim, update validator unbond info
    /// @param claimAmount claim amount
    function unStake(uint256 claimAmount) external override isStZETA {
        /*
        1. Perform unstaking, return shares and withdraw pool shares calculated from user withdrawal amount
        2. Get user unbondNonce, and increase by 1
        3. Construct a DelegatorUnbond structure, put in withdraw pool shares and current epoch 
        4. Update user unbonds_new mapping and unbondNonces mapping
        */
        require(claimAmount > 0, "zero amount");
        require(claimAmount <= totalStake, "exceed totalStake");
        uint256 currentEpoch = IStZETA(stZETA).currentEpoch();
        uint256 epochDelay = IStZETA(stZETA).epochDelay();
        // update total stake
        totalStake -= claimAmount;
        // get user unbondNonce, and increase by 1
        uint256 unbondNonce = unbondNonces[msg.sender] + 1;
        // construct a DelegatorUnbond structure
        DelegatorUnbond memory unbond = DelegatorUnbond({
            amount: claimAmount,
            withdrawEpoch: currentEpoch + epochDelay
        });
        // set unbondNonce corresponding unbond info
        unbonds_new[msg.sender][unbondNonce] = unbond;
        // update unbondNonce
        unbondNonces[msg.sender] = unbondNonce;
        // // update unbondEpochsNonces
        // unbondEpochsNonces[currentEpoch].push(unbondNonce);

        emit UnStake(currentEpoch, claimAmount, unbondNonce, totalStake);
    }

    /// @notice get address unbond nonces
    /// @param user user address
    /// @return unbond nonces
    function getUnbondNonces(address user) external view override returns (uint256) {
        return unbondNonces[user];
    }

    /// @notice get user nonce corresponding unbond info 
    /// @param user user address
    /// @param unbondNonce unbond nonce
    /// @return unbond info
    function getDelegatorUnbond(address user, uint256 unbondNonce) external view override returns (DelegatorUnbond memory) {
        return unbonds_new[user][unbondNonce];
    }

    /// @notice get epoch unbond nonces
    /// @param epoch epoch
    /// @return unbond nonces
    function getUnbondEpochsNonces(uint256 epoch) external view override returns (uint256[] memory) {
        return unbondEpochsNonces[epoch];
    }

    /// @notice get epoch finished unbond nonces
    /// @param epoch epoch
    /// @return unbond nonces
    function getFinishedUnbondEpochsNonces(uint256 epoch) external view override returns (uint256[] memory) {
        return finishedUnbondEpochsNonces[epoch];
    }

    /// @notice add oracle reward to total stake
    /// @param rewardAmount reward amount
    function addOracleReward(uint256 rewardAmount) external override onlyRole(ORACLE_ROLE) {
        // update total stake
        totalStake += rewardAmount;
        emit AddOracleReward(rewardAmount, totalStake);
    }

    /// @notice subtract oracle punish from total stake
    /// @param punishAmount punish amount 
    function subOraclePunish(uint256 punishAmount) external override onlyRole(ORACLE_ROLE) {
        // update total stake
        totalStake -= punishAmount;
        emit SubOracleReward(punishAmount, totalStake);
    }

    /// @notice get update version each time
    function getUpdateVersion() external pure override returns(string memory) {
        return "1.0.2.3";
    }

    /// @notice get finished unbond epoch amount
    function getfinishedUnbondEpochAmount(uint256 epoch) external view override returns (uint256) {
        return finishedUnbondEpochAmount[epoch];
    }

    /// @notice receive finished unbond call
    /// @param delegator_address delegator address
    /// @param end_epoch end_epoch
    /// @param blockHeight block height
    /// only oracle can call this function
    function finishUnbond(
        address delegator_address,
        uint256 end_epoch,
        uint256 blockHeight
    ) external payable override onlyRole(ORACLE_ROLE) {
        // get the unbond value
        uint256 unbondAmount = msg.value;
        // ensure the unbondAmount is not zero
        require(unbondAmount > 0, "zero amount");

        // update finishedUnbondEpochAmount
        finishedUnbondEpochAmount[end_epoch] += unbondAmount;
        // update totalUnbondEpochAmount
        totalUnbondAmount += unbondAmount;
        // update lastEpochFinishedUnbond
        if (end_epoch > lastEpochFinishedUnbond) {
            lastEpochFinishedUnbond = end_epoch;
        }

        // emit event
        emit FinishUnbond(
            unbondAmount, end_epoch, blockHeight, delegator_address, totalUnbondAmount);
    }

    /// @notice let stZETA to run unstake claim
    /// @param unbondNonce unbond nonce
    /// @return claim amount
    function unstakeClaimTokens(uint256 unbondNonce) external override isStZETA returns(uint256) {
        // get user unbond info
        DelegatorUnbond memory unbond = unbonds_new[msg.sender][unbondNonce];
        // according to unbond info to unstake claim, it will transfer amount to user
        uint256 amount = _unstakeClaimTokens(unbond);
        // delete unbonds_new[msg.sender][unbondNonce];
        delete unbonds_new[msg.sender][unbondNonce];

        return amount;
    }

    /// @notice set total unbond amount
    /// @param _totalUnbondAmount total unbond amount
    function setTotalUnbondAmount(uint256 _totalUnbondAmount) external override onlyRole(ORACLE_ROLE) {
        uint256 oldTotalUnbondAmount = totalUnbondAmount;
        totalUnbondAmount = _totalUnbondAmount;
        emit SetTotalUnbondAmount(oldTotalUnbondAmount, _totalUnbondAmount);
    }

    function setFinishedUnbondEpochAmount(uint256 epoch, uint256 amount) external override onlyRole(ORACLE_ROLE) {
        uint256 oldAmount = finishedUnbondEpochAmount[epoch];
        finishedUnbondEpochAmount[epoch] = amount;
        emit SetFinishedUnbondEpochAmount(epoch, oldAmount, amount);
    }

    /// @notice according to unbond info to unstake claim, it will transfer amount to user
    function _unstakeClaimTokens(DelegatorUnbond memory unbond) private returns(uint256) {
        // get user unbond amount
        uint256 amount = unbond.amount;
        uint256 end_epoch = unbond.withdrawEpoch;
        // require user's withdrawEpoch has passed withdrawalDelay, and user's unbond amount > 0
        require(
            end_epoch <= IStZETA(stZETA).currentEpoch() && amount > 0,
            "Incomplete epoch period"
        );
        // ensure user's unbond amount <= total unbond amount, and user's unbond amount <= finishedUnbondEpochAmount
        require(
            (amount <= totalUnbondAmount) && (amount <= finishedUnbondEpochAmount[end_epoch]), 
            "Invalid amount");
        // update totalUnbondAmount and finishedUnbondEpochAmount
        finishedUnbondEpochAmount[end_epoch] -= amount;
        totalUnbondAmount -= amount;
        // send amount to stZETA
        IStZETA(stZETA).receiveZETA{value: amount}();
        
        return amount;
    }

    ////////////////////////////////////////////////////////////
    /////                                                    ///
    /////                    Setters                         ///
    /////                                                    ///
    ////////////////////////////////////////////////////////////

    /// @notice Set new contract version
    /// @notice Only DAO role can call this function
    /// @param _newVersion - New contract version
    function setVersion(string memory _newVersion)
        external
        override
        onlyRole(DAO_ROLE) {
        string memory oldVersion = version;
        version = _newVersion;
        emit SetVersion(oldVersion, _newVersion);
    }

    /// @notice Set new ratio
    /// @notice Only ORACLE role can call this function
    /// @param _newRatio - New ratio
    function setRatio(uint256 _newRatio) external override onlyRole(ORACLE_ROLE) {
        uint256 oldRatio = ratio;
        ratio = _newRatio;
        emit SetRatio(oldRatio, _newRatio);
    }

    /// @notice Set new status
    /// @notice Only ORACLE role can call this function
    /// @param _newStatus - New status
    function setStatus(NodeOperatorRegistryStatus _newStatus)
        external
        override
        onlyRole(ORACLE_ROLE) {
        NodeOperatorRegistryStatus oldStatus = status;
        status = _newStatus;
        emit SetStatus(oldStatus, _newStatus);
    }

    /// @notice Set new DAO address
    /// @notice Only DAO role can call this function
    /// @param _newDAO - New DAO address
    function setDao(address _newDAO) external override onlyRole(DAO_ROLE) {
        address oldDAO = dao;
        dao = _newDAO;
        emit SetDao(oldDAO, _newDAO);
    }

    /// @notice Set new oracle address
    /// @notice Only DAO role can call this function
    /// @param _newOracle - New oracle address
    function setOracle(address _newOracle)
        external
        override
        onlyRole(DAO_ROLE) {
        address oldOracle = oracle;
        oracle = _newOracle;
        emit SetOracle(oldOracle, _newOracle);
    }

    /// @notice Set new stZETA address
    /// @notice Only DAO role can call this function
    /// @param _newStZETA - New stZETA address
    function setStZETA(address _newStZETA)
        external
        override
        onlyRole(DAO_ROLE) {
        address oldStZETA = stZETA;
        stZETA = _newStZETA;
        emit SetStZETA(oldStZETA, _newStZETA);
    }

    /// @notice Set new delegation address
    /// @notice Only DAO role can call this function
    /// @param _newDelegateAddress - New delegation address
    function setDelegateAddress(address _newDelegateAddress)
        external
        override
        onlyRole(DAO_ROLE) {
        address oldDelegateAddress = delegateAddress;
        delegateAddress = _newDelegateAddress;
        emit SetDelegateAddress(oldDelegateAddress, _newDelegateAddress);
    }

    /// @notice Set new reward address
    /// @notice Only DAO role can call this function
    /// @param _newRewardAddress - New reward address
    function setRewardAddress(address _newRewardAddress)
        external
        override
        onlyRole(DAO_ROLE) {
        address oldRewardAddress = rewardAddress;
        rewardAddress = _newRewardAddress;
        emit SetRewardAddress(oldRewardAddress, _newRewardAddress);
    }

    /// @notice Set new totalStake
    /// @notice Only ORACLE role can call this function
    /// @param _newTotalStake - New totalStake
    function setTotalStake(uint256 _newTotalStake)
        external
        override
        onlyRole(ORACLE_ROLE) {
        uint256 oldTotalStake = totalStake;
        totalStake = _newTotalStake;
        emit SetTotalStake(oldTotalStake, _newTotalStake);
    }

    /// @notice Set new commission rate
    /// @notice Only ORACLE role can call this function
    /// @param _newCommissionRate - New commission rate
    function setCommissionRate(uint16 _newCommissionRate)
        external
        override
        onlyRole(ORACLE_ROLE) {
        uint16 oldCommissionRate = commissionRate;
        commissionRate = _newCommissionRate;
        emit SetCommissionRate(oldCommissionRate, _newCommissionRate);
    }


    /// @notice Set user nonce corresponding unbond info
    /// @param _user User address
    /// @param _unbondNonces Unbond nonce
    /// @param _target_epoch Target epoch
    function setNoncesEpoch(address _user, uint256[] memory _unbondNonces, uint256 _target_epoch) 
        external override onlyRole(DAO_ROLE) {
        for (uint256 i = 0; i < _unbondNonces.length; i++) {
            unbonds_new[_user][_unbondNonces[i]].withdrawEpoch = _target_epoch;
        }
        emit SetNoncesEpoch(_user, _target_epoch, _unbondNonces);
    }


    /// @notice Insert finished epoch nonce
    /// @notice Only ORACLE role can call this function
    /// @param epoch - Finished epoch
    /// @param nonce - Finished nonce
    function pushFinishedUnbondEpochsNonces(uint256 epoch, uint256 nonce)
        external
        override
        onlyRole(ORACLE_ROLE) {
        finishedUnbondEpochsNonces[epoch].push(nonce);
        emit PushFinishedUnbondEpochsNonces(epoch, nonce);
    }

    /// @notice Pause contract
    function pause() external onlyRole(PAUSE_ROLE) {
        _pause();
    }

    /// @notice Unpause contract
    function unpause() external onlyRole(UNPAUSE_ROLE) {
        _unpause();
    }

}