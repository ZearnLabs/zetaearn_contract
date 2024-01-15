// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "./interfaces/IValidatorOperator.sol";
import "./interfaces/INodeOperatorRegistry.sol";


contract NodeOperatorRegistry is
    INodeOperatorRegistry,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    /// @notice All roles.
    bytes32 public constant DAO_ROLE = keccak256("ZETAEARN_DAO");
    bytes32 public constant PAUSE_ROLE = keccak256("ZETAEARN_PAUSE_OPERATOR");
    bytes32 public constant UNPAUSE_ROLE = keccak256("ZETAEARN_UNPAUSE_OPERATOR");
    bytes32 public constant ADD_NODE_OPERATOR_ROLE =
        keccak256("ZETAEARN_ADD_NODE_OPERATOR_ROLE");
    bytes32 public constant REMOVE_NODE_OPERATOR_ROLE =
        keccak256("ZETAEARN_REMOVE_NODE_OPERATOR_ROLE");

    /// @notice Contract version.
    string public version;

    /// @notice DAO address.
    address public override dao;

    /// @notice List of all validator addresses.
    address[] public operatorAddresses;

    /// @notice Mapping of owner to node operator address. Mapping allows extendable struct.
    mapping(address => address) public validatorOperatorAddressToRewardAddress;

    /// @notice Mapping of validator reward address to validator address. Mapping allows extendable struct.
    mapping(address => address) public validatorRewardAddressToOperatorAddress;

    // -------------------------------------
    // after staking slot
    // -------------------------------------
    
    /// @notice Initialize NodeOperatorRegistry contract.
    function initialize(address _dao) external initializer {
        __Pausable_init_unchained();
        __AccessControl_init_unchained();
        __ReentrancyGuard_init_unchained();

        // Set roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSE_ROLE, msg.sender);
        _grantRole(UNPAUSE_ROLE, _dao);
        _grantRole(DAO_ROLE, _dao);
        _grantRole(ADD_NODE_OPERATOR_ROLE, _dao);
        _grantRole(REMOVE_NODE_OPERATOR_ROLE, _dao);

        // Set addresses
        dao = _dao;

        version = "1.0.2";
    }

    /// @notice Add new node operator to the system.  
    /// Only ADD_NODE_OPERATOR_ROLE can execute this function.
    /// @param _operatorAddress - validator address.
    /// Overall flow is to validate validator compliance then add to validator related 3 data structures
    function addNodeOperator(address _operatorAddress)
        external
        override
        onlyRole(ADD_NODE_OPERATOR_ROLE)
        nonReentrant {
        // Operator address cannot be 0
        require(_operatorAddress != address(0), "invalid operator address");
        // Operator address cannot already exist
        require(
            validatorOperatorAddressToRewardAddress[_operatorAddress] == address(0),
            "operator exists"
        );
        // Get validator
        IValidatorOperator validator = IValidatorOperator(_operatorAddress);
        address _rewardAddress = validator.rewardAddress();
        address _delegateAddress = validator.delegateAddress();
        // Reward address cannot already exist
        require(
            validatorRewardAddressToOperatorAddress[_rewardAddress] == address(0),
            "reward exists"
        );
        // Reward address cannot be 0
        require(_rewardAddress != address(0), "Invalid reward address");
        // Delegate address cannot be 0
        require(_delegateAddress != address(0), "Invalid delegate address");
        // Validator status must be active
        require(
            validator.status() == IValidatorOperator.NodeOperatorRegistryStatus.ACTIVE,
            "Validator isn't ACTIVE"
        );
        // Update validator address to reward address mapping
        validatorOperatorAddressToRewardAddress[_operatorAddress] = _rewardAddress;
        // Update reward address to validator address mapping
        validatorRewardAddressToOperatorAddress[_rewardAddress] = _operatorAddress;
        // Add validator address to validator address list
        operatorAddresses.push(_operatorAddress);

        emit AddNodeOperator(_operatorAddress, _delegateAddress, _rewardAddress);
    }

    /// @notice Exit node operator registry
    /// Only callable by node operator owner
    function exitNodeOperatorRegistry() external override nonReentrant {
        // Get validator address
        address operatorAddress = validatorRewardAddressToOperatorAddress[msg.sender];
        // Get reward address
        address rewardAddress = validatorOperatorAddressToRewardAddress[operatorAddress];
        // Reward address must be caller
        require(rewardAddress == msg.sender, "Unauthorized");
        // Get validator
        IValidatorOperator validator = IValidatorOperator(operatorAddress);
        // Remove from validator ID to reward address mapping
        _removeOperator(operatorAddress, rewardAddress);
        emit ExitNodeOperator(operatorAddress, validator.delegateAddress(), rewardAddress);
    }

    /// @notice Remove a node operator from the system and update its status to allow oracle to withdraw all delegated tokens
    /// Only callable by DAO
    /// @param operatorAddress validator's validator operator address
    function removeNodeOperator(address operatorAddress)
        external
        override
        onlyRole(REMOVE_NODE_OPERATOR_ROLE)
        nonReentrant {
        // Get reward address
        address rewardAddress = validatorOperatorAddressToRewardAddress[operatorAddress];
        // Reward address cannot be 0
        require(rewardAddress != address(0), "Validator doesn't exist");
        // Get validator
        IValidatorOperator validator = IValidatorOperator(operatorAddress);
        // Remove from validator address to reward address mapping
        _removeOperator(operatorAddress, rewardAddress);

        emit RemoveNodeOperator(operatorAddress, validator.delegateAddress(), rewardAddress);
    }

    /// @notice Remove a node operator if it does not meet some conditions from the system
    /// 1. If node operator commission is less than standard commission
    /// 2. If node operator is Unstaked or Ejected
    /// @param operatorAddress validator's validator operator address
    function removeInvalidNodeOperator(address operatorAddress)
        external
        override
        whenNotPaused
        nonReentrant {
        // Get reward address
        address rewardAddress = validatorOperatorAddressToRewardAddress[operatorAddress];
        // Get validator status and validator
        IValidatorOperator validator = IValidatorOperator(operatorAddress);
        IValidatorOperator.NodeOperatorRegistryStatus operatorStatus = validator.status();
        // Validator status must not be unstaked or ejected
        require(
            operatorStatus == IValidatorOperator.NodeOperatorRegistryStatus.UNSTAKED ||
                operatorStatus == IValidatorOperator.NodeOperatorRegistryStatus.EJECTED,
            "Cannot remove valid operator."
        );
        // Remove from validator address to reward address mapping
        _removeOperator(operatorAddress, rewardAddress);

        emit RemoveInvalidNodeOperator(operatorAddress, validator.delegateAddress(), rewardAddress);
    }

    // Remove operator
    function _removeOperator(address _operatorAddress, address _rewardAddress) private {
        // Iterate through validator IDs list to remove 
        uint256 length = operatorAddresses.length;
        for (uint256 idx = 0; idx < length - 1; idx++) {
            if (_operatorAddress == operatorAddresses[idx]) {
                operatorAddresses[idx] = operatorAddresses[length - 1];
                break;
            }
        }
        operatorAddresses.pop();
        // Update validator to withdraw all delegated flagged, for oracle to execute
        IValidatorOperator validator = IValidatorOperator(_operatorAddress);
        validator.withdrawTotalDelegated();
        // Remove from validator address to reward address mapping
        delete validatorOperatorAddressToRewardAddress[_operatorAddress];
        delete validatorRewardAddressToOperatorAddress[_rewardAddress];
    }

    /// @notice Get update version on each update
    function getUpdateVersion() external pure override returns(string memory) {
        return "1.0.2.3";
    }

    ////////////////////////////////////////////////////////////
    /////                                                    ///
    /////                    Setters                         ///
    /////                                                    ///
    ////////////////////////////////////////////////////////////

    /// @notice Update node operator's reward address.  
    function setRewardAddress(address _newRewardAddress)
        external
        override
        whenNotPaused
    {
        require(_newRewardAddress != msg.sender, "Invalid reward address");
        address operatorAddress = validatorRewardAddressToOperatorAddress[msg.sender];
        address oldRewardAddress = validatorOperatorAddressToRewardAddress[operatorAddress];
        require(oldRewardAddress == msg.sender, "Unauthorized");
        require(_newRewardAddress != address(0), "Invalid reward address");

        validatorOperatorAddressToRewardAddress[operatorAddress] = _newRewardAddress;
        validatorRewardAddressToOperatorAddress[_newRewardAddress] = operatorAddress;
        delete validatorRewardAddressToOperatorAddress[msg.sender];

        emit SetRewardAddress(operatorAddress, oldRewardAddress, _newRewardAddress);
    }

    /// @notice Set contract version.
    /// @notice Only callable by DAO role.
    /// @param _newVersion - New contract version.
    function setVersion(string memory _newVersion)
        external
        override
        onlyRole(DAO_ROLE) {
        string memory oldVersion = version;
        version = _newVersion;
        emit SetVersion(oldVersion, _newVersion);
    }

    /// @notice Pause contract
    function pause() external onlyRole(PAUSE_ROLE) {
        _pause();
    }

    /// @notice Unpause contract
    function unpause() external onlyRole(UNPAUSE_ROLE) {
        _unpause();
    }

    ////////////////////////////////////////////////////////////
    /////                                                    ///
    /////                    Getters                         ///
    /////                                                    ///
    ////////////////////////////////////////////////////////////

    /// @notice List all delegated, active operators from stakeManager.
    function listDelegatedNodeOperators()
        external
        view
        override
        returns (ValidatorData[] memory) {
        return _listNodeOperators(true);
    }

    /// @notice List all operators that can be withdrawn from including active, jailed, ejected and unstaked operators.
    /// I.e. any operator that funds can be taken out of regardless of operator status. Only INACTIVE status operators not listed.
    /// @return nodeOperators A list of active, jailed, ejected or unstaked node operators.
    function listWithdrawNodeOperators()
        external
        view
        override
        returns (ValidatorData[] memory) {
        return _listNodeOperators(false);
    }

    /// @notice List all operators that can be withdrawn from including active, jailed, ejected and unstaked operators.
    /// @param _isForDelegation Whether it is for delegation
    /// @return nodeOperators A list of active, jailed, ejected or unstaked node operators.
    function _listNodeOperators(bool _isForDelegation)
        private
        view
        returns (ValidatorData[] memory){
        // Total node operators
        uint256 totalNodeOperators = 0;
        // Temp validator
        IValidatorOperator validator;
        // Temp operator status
        IValidatorOperator.NodeOperatorRegistryStatus operatorStatus;
        // Validator address list
        address[] memory memOperatorAddresses = operatorAddresses;
        // Length of validator IDs list
        uint256 length = memOperatorAddresses.length;
        // Newly created list of node operators
        ValidatorData[] memory activeValidators = new ValidatorData[](length);
        // Iterate through validator IDs list
        for (uint256 i = 0; i < length; i++) {
            // Get reward address
            address rewardAddress = validatorOperatorAddressToRewardAddress[memOperatorAddresses[i]];
            // Get node operator status and validator
            validator = IValidatorOperator(memOperatorAddresses[i]);
            operatorStatus = validator.status();
            // Get node status, different condition based on whether it is for delegation
            // For delegate condition is validator status is active and validator supports delegation
            // For withdraw condition is validator status is not inactive 
            bool condition = _listNodeOperatorCondition(operatorStatus, _isForDelegation);
            if (!condition) continue;
            // Add to node operators list
            activeValidators[totalNodeOperators] = ValidatorData(
                memOperatorAddresses[i],
                validator.delegateAddress(),
                rewardAddress
            );
            // Increment node operators count
            totalNodeOperators++;
        }
        // If node operators count less than validator IDs list length, reallocate memory
        if (totalNodeOperators < length) {
            assembly {
                mstore(activeValidators, totalNodeOperators)
            }
        }
        // Return node operators list
        return activeValidators;
    }

    /// @notice Get validator status and validator
    /// @param _operatorStatus Node operator status
    /// @param _isForDelegation Whether it is for delegation
    /// @return status Node operator status
    function _listNodeOperatorCondition(
        IValidatorOperator.NodeOperatorRegistryStatus _operatorStatus,
        bool _isForDelegation
    ) private pure returns (bool) {
        // If for delegation, check validator status is active and supports delegation
        if (_isForDelegation) {
            if (_operatorStatus == IValidatorOperator.NodeOperatorRegistryStatus.ACTIVE) return true;
            return false;
        } else {
            // Otherwise check validator status is not inactive
            if (_operatorStatus != IValidatorOperator.NodeOperatorRegistryStatus.INACTIVE) return true;
            return false;
        }
    }

    /// @notice Calculate how total buffered should be allocated across active validators depending on if system is balanced
    /// If validators are EJECTED or UNSTAKED this function will revert
    /// @return validators All active node operators
    /// @return stakePerOperator Stake per node operator  
    /// @return operatorRatios Ratio list for each node operator. 
    /// @return totalRatio Total ratio
    /// @return totalStaked Total staked
    function getValidatorsDelegationAmount()
        external
        view
        override
        returns (
            ValidatorData[] memory validators,
            uint256[] memory stakePerOperator,
            uint256[] memory operatorRatios,
            uint256 totalRatio,
            uint256 totalStaked
        )
    {
        // Require at least 1 node operator
        require(operatorAddresses.length > 0, "Not enough operators to delegate");
        // Get validator status and validator
        // Here validators is list of all active node operators
        // stakePerOperator is delegate amount per node operator
        // totalStaked is total delegate amount across node operators
        // distanceMinMaxStake is distance between min and max delegate amount
        (
            validators,
            stakePerOperator,
            operatorRatios,
            totalStaked,
            totalRatio
        ) = _getValidatorsDelegationInfos();
    }

    /// @notice Return all active operator delegation infos.
    /// @return validators List of all active node operators.
    /// @return stakePerOperator Delegate amount within each validator.
    /// @return operatorRatios Ratio list for each validator.
    /// @return totalStaked Total delegate amount across active validators.  
    /// @return totalRatio Total ratio across active node operators.
    function _getValidatorsDelegationInfos()
        private
        view
        returns (
            ValidatorData[] memory validators,
            uint256[] memory stakePerOperator,
            uint256[] memory operatorRatios,
            uint256 totalStaked,
            uint256 totalRatio
        ) {
        // Active operators count
        uint256 activeOperatorCount;
        // Validator IDs list
        address[] memory operatorAddressesMem = operatorAddresses;
        // Newly created list of node operators
        validators = new ValidatorData[](operatorAddressesMem.length);
        // Newly created delegate amount per validator list
        stakePerOperator = new uint256[](operatorAddressesMem.length);
        // Newly created ratio list per validator
        operatorRatios = new uint256[](operatorAddressesMem.length);
        // Temp validator address
        address operatorAddress;
        // Temp reward address
        address rewardAddress;
        // Temp validator
        IValidatorOperator validator;
        // Temp operator status
        IValidatorOperator.NodeOperatorRegistryStatus status;
        // Iterate through validator address list
        for (uint256 i = 0; i < operatorAddressesMem.length; i++) {
            // Get validator address
            operatorAddress = operatorAddressesMem[i];
            // Get reward address
            rewardAddress = validatorOperatorAddressToRewardAddress[operatorAddress];
            // Get node operator status and validator
            validator = IValidatorOperator(operatorAddress);
            status = validator.status();
            // If node operator status is inactive, skip
            if (status == IValidatorOperator.NodeOperatorRegistryStatus.INACTIVE) continue;
            // Require node operator status is not ejected
            require(
                !(status == IValidatorOperator.NodeOperatorRegistryStatus.EJECTED),
                "Could not calculate the stake data, an operator was EJECTED"
            );
            // Require node operator status is not unstaked
            require(
                !(status == IValidatorOperator.NodeOperatorRegistryStatus.UNSTAKED),
                "Could not calculate the stake data, an operator was UNSTAKED"
            );
            // Get validator total delegated in stZETA contract
            uint256 amount = validator.totalStake();
            // Add to total staked
            totalStaked += amount;
            // If node operator status is active and supports delegation, add to node operators list
            if (status == IValidatorOperator.NodeOperatorRegistryStatus.ACTIVE) 
            {
                // Update delegate amount per validator
                stakePerOperator[activeOperatorCount] = amount;
                // Update node operators list at index
                validators[activeOperatorCount] = ValidatorData(
                    operatorAddress,
                    validator.delegateAddress(),
                    rewardAddress
                );
                // Update node operator ratio 
                operatorRatios[activeOperatorCount] = validator.ratio();
                // Increment active operators count
                activeOperatorCount++;
                // Update total ratio
                totalRatio += validator.ratio();
            }
        }
        // Require at least 1 active validator
        require(activeOperatorCount > 0, "There are no active validator");

        // If active validators count less than validator IDs list length, reallocate memory
        if (activeOperatorCount < operatorAddressesMem.length) {
            assembly {
                mstore(validators, activeOperatorCount)
                mstore(stakePerOperator, activeOperatorCount)
                mstore(operatorRatios, activeOperatorCount)
            }
        }
    }

    /// @notice Return a node operator
    /// @param operatorAddress validator's validator operator address
    /// @return nodeOperator A node operator
    function getNodeOperatorByOperatorAddress(address operatorAddress)
        external
        view
        returns (FullNodeOperatorRegistry memory nodeOperator) {
        // Get reward address
        address rewardAddress = validatorOperatorAddressToRewardAddress[operatorAddress];
        require(rewardAddress != address(0), "Reward not found");
        // Get node operator status and validator
        IValidatorOperator validator = IValidatorOperator(operatorAddress);
        // Get node operator other infos
        nodeOperator.operatorAddress = operatorAddress;
        nodeOperator.delegateAddress = validator.delegateAddress();
        nodeOperator.rewardAddress = rewardAddress;
        nodeOperator.status = validator.status();
        nodeOperator.commissionRate = validator.commissionRate();
    }

    // @notice Return a node operator
    /// @param rewardAddress Reward address
    /// @return nodeOperator A node operator
    function getNodeOperatorByRewardAddress(address rewardAddress)
        external
        view
        returns (FullNodeOperatorRegistry memory nodeOperator) {
        // Get operator address from reward address
        address operatorAddress = validatorRewardAddressToOperatorAddress[rewardAddress];
        require(operatorAddress != address(0), "Operator not found");
        // Get node operator status and validator
        IValidatorOperator validator = IValidatorOperator(operatorAddress);
        // Get node operator other infos
        nodeOperator.operatorAddress = operatorAddress;
        nodeOperator.delegateAddress = validator.delegateAddress();
        nodeOperator.rewardAddress = rewardAddress;
        nodeOperator.status = validator.status();
        nodeOperator.commissionRate = validator.commissionRate();
    }

    /// @notice Return a node operator's status
    /// @param  operatorAddress Node operator address  
    /// @return operatorStatus Return a node operator's status
    function getNodeOperatorStatus(address operatorAddress)
        external
        view
        returns (IValidatorOperator.NodeOperatorRegistryStatus operatorStatus) {
        // Ensure node operator exists via reward address
        address rewardAddress = validatorOperatorAddressToRewardAddress[operatorAddress];
        require(rewardAddress != address(0), "Reward not found");
        // Get node operator status and validator
        IValidatorOperator validator = IValidatorOperator(operatorAddress);
        operatorStatus = validator.status();
    }


    /// @notice Return list of all operatorAddresses
    function getOperatorAddresses() external view returns (address[] memory) {
        return operatorAddresses;
    }

    /// @notice Calculate if validators can withdraw from depending on if system is balanced
    /// @param _withdrawAmount Amount that can be withdrawn
    /// @return validators All node operators
    /// @return totalDelegated Total delegated
    /// @return bigNodeOperatorAddresses Addresses of node operators with delegation above average 
    /// @return smallNodeOperatorAddresses Addresses of node operators with delegation below average
    /// @return operatorAmountCanBeRequested Amount that can be requested from specific validator if system imbalanced
    /// @return totalValidatorToWithdrawFrom Number of validators to withdraw from if system balanced  
    /// @return minStakeAmount Minimum validator stake if system balanced
    function getValidatorsRequestWithdraw(uint256 _withdrawAmount)
    external
    view
    override
    returns (
        ValidatorData[] memory validators,
        uint256 totalDelegated,
        address[] memory bigNodeOperatorAddresses,
        address[] memory smallNodeOperatorAddresses,
        uint256[] memory operatorAmountCanBeRequested,
        uint256 totalValidatorToWithdrawFrom,
        uint256 minStakeAmount
    ) {
        require(_withdrawAmount > 0, "Invalid amount");
        // Require at least 1 node operator
        if (operatorAddresses.length == 0) {
            return (
                validators,
                totalDelegated,
                bigNodeOperatorAddresses,
                smallNodeOperatorAddresses,
                operatorAmountCanBeRequested,
                totalValidatorToWithdrawFrom,
                0
            );
        }
        uint256[] memory stakePerOperator;
        uint256 minAmount;
        uint256 maxAmount;
        // Get all active validator infos
        (
            validators,
            stakePerOperator,
            totalDelegated,
            minAmount,
            maxAmount
        ) = _getValidatorsRequestWithdraw();
        // If currently no delegation, directly return
        if (totalDelegated == 0) {
            return (
                validators,
                totalDelegated,
                bigNodeOperatorAddresses,
                smallNodeOperatorAddresses,
                operatorAmountCanBeRequested,
                totalValidatorToWithdrawFrom,
                0
            );
        }
        // // This logic is there is a min share per validator, if amount is small may not need all validators to withdraw
        // // Get withdraw amount percentage of total delegation
        // uint256 length = validators.length;
        // uint256 withdrawAmountPercentage = (_withdrawAmount * 100) /
        //     totalDelegated;
        // // totalValidatorToWithdrawFrom is number of validators to withdraw from
        // // Formula here is number of validators to withdraw from = ((withdraw amount percentage + MIN_REQUEST_WITHDRAW_RANGE_PERCENTS) * number of validators / 100) + 1
        // // I.e. if withdrawAmountPercentage is 0, number of validators to withdraw from will be MIN_REQUEST_WITHDRAW_RANGE_PERCENTS
        // totalValidatorToWithdrawFrom = (((withdrawAmountPercentage + MIN_REQUEST_WITHDRAW_RANGE_PERCENTS) * length) / 100) + 1;
        // // Require at least 1 validator to withdraw from
        // totalValidatorToWithdrawFrom = min(totalValidatorToWithdrawFrom, length);
        totalValidatorToWithdrawFrom = validators.length;
        // Only consider balanced for now
        // // min validator share * number of validators > amount to withdraw
        // // and ratio of maxAmount to minAmount < 1.2 
        // // I.e. can safely evenly allocate if returned here
        // if (
        //     minAmount * totalValidatorToWithdrawFrom >= _withdrawAmount &&
        //     (maxAmount * 100) / minAmount <= DISTANCE_THRESHOLD_PERCENTS
        // ) {
        //     return (
        //         validators,
        //         totalDelegated,
        //         bigNodeOperatorIds,
        //         smallNodeOperatorIds,
        //         operatorAmountCanBeRequested,
        //         totalValidatorToWithdrawFrom
        //     );
        // }
        return (
            validators,
            totalDelegated,
            bigNodeOperatorAddresses,
            smallNodeOperatorAddresses,
            operatorAmountCanBeRequested,
            totalValidatorToWithdrawFrom,
            minAmount
        );
    }

    /// @notice Return active operator infos.
    /// @return activeValidators All active node operators.
    /// @return stakePerOperator Delegate amount per validator. 
    /// @return totalDelegated Total delegation across validators.
    /// @return minAmount Minimum delegation in validator.
    /// @return maxAmount Maximum delegation in validator.
    function _getValidatorsRequestWithdraw()
    private
    view
    returns (
        ValidatorData[] memory activeValidators,
        uint256[] memory stakePerOperator,
        uint256 totalDelegated,
        uint256 minAmount,
        uint256 maxAmount
    ) {
        address[] memory operatorAddressesMem = operatorAddresses;
        activeValidators = new ValidatorData[](operatorAddressesMem.length);
        stakePerOperator = new uint256[](operatorAddressesMem.length);

        address rewardAddress;
        IValidatorOperator validator;
        IValidatorOperator.NodeOperatorRegistryStatus status;
        minAmount = type(uint256).max;
        uint256 activeValidatorsCounter;

        // Iterate through validator list
        for (uint256 i = 0; i < operatorAddresses.length; i++) {
            // Get reward address
            rewardAddress = validatorOperatorAddressToRewardAddress[operatorAddresses[i]];
            // Get validator status and validator
            // Get node operator status and validator
            validator = IValidatorOperator(operatorAddresses[i]);
            status = validator.status();
            // If validator status is inactive, skip
            if (status ==  IValidatorOperator.NodeOperatorRegistryStatus.INACTIVE) continue;

            // Get validator total delegated in stZETA contract
            uint256 amount = validator.totalStake();
            // Update return values
            stakePerOperator[activeValidatorsCounter] = amount;
            totalDelegated += amount;
            // Update min max delegation
            if (maxAmount < amount) {
                maxAmount = amount;
            }
            if (minAmount > amount) {
                minAmount = amount;
            }
            // Update active node operators list and count
            activeValidators[activeValidatorsCounter] = ValidatorData(
                operatorAddresses[i],
                validator.delegateAddress(),
                rewardAddress
            );
            activeValidatorsCounter++;
        }
        // If active node operators count less than validator IDs list length, reallocate memory
        if (activeValidatorsCounter < operatorAddresses.length) {
            assembly {
                mstore(activeValidators, activeValidatorsCounter)
                mstore(stakePerOperator, activeValidatorsCounter)
            }
        }
    }
}