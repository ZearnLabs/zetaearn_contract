// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import "./interfaces/IStZETA.sol";
import "./interfaces/INodeOperatorRegistry.sol";
import "./interfaces/IValidatorOperator.sol";
import "./interfaces/IUnStZETA.sol";

contract StZETA is
    IStZETA,
    ERC20Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable
{
    /// @notice Wrapper for ERC20 operations, throws an error if failed
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /// @notice All roles
    bytes32 public constant override DAO = keccak256("ZETAEARN_DAO");
    bytes32 public constant ORACLE_ROLE = keccak256("ZETAEARN_ORACLE");
    bytes32 public constant override PAUSE_ROLE = keccak256("ZETAEARN_PAUSE_OPERATOR");
    bytes32 public constant override UNPAUSE_ROLE = keccak256("ZETAEARN_UNPAUSE_OPERATOR");

    /// @notice Fee distribution
    FeeDistribution public override entityFees;

    /// @notice Contract version
    string public override version;

    /// @notice DAO address
    address public override dao;

    /// @notice Oracle address
    address public override oracle;

    /// @notice Insurance address
    address public override insurance;

    /// @notice Node Operator Registry contract interface
    INodeOperatorRegistry public override nodeOperatorRegistry;

    /// @notice Total buffered ZETA in the contract
    // Here, totalBuffered only increases in two cases:
    // 1. Users submit ZETA, which mints stZETA and increases totalBuffered
    // 2. claimTokensFromValidatorToContract, which extracts ZETA from validatorShare and increases totalBuffered
    uint256 public override totalBuffered;

    /// @notice Reserved funds in ZETA
    /// Here, reservedFunds refers to the amount of ZETA corresponding to stZETA when users apply for withdrawal
    uint256 public override reservedFunds;

    /// @notice Protocol fee
    uint8 public override protocolFee;

    /// @notice Submission threshold
    uint256 public override submitThreshold;

    /// @notice Total number of unique stakers
    uint256 public override totalStakers;

    /// @notice Daily annual percentage rate (APR), with two decimal places, represented as a percentage with a total of 5 digits
    uint16 public override apr;

    /// @notice Delegation lower bound
    uint256 public override delegationLowerBound;

    /// @notice All users who have ever staked
    mapping(address => bool) private _stakers;

    // @notice These state variables are used to mark entry and exit of contract functions
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    // @notice Used for executing recovery once
    bool private recovered;

    // -------------------------------------
    // after staking slot
    // -------------------------------------

    /// @notice Maximum submission threshold
    uint256 public override submitMaxThreshold;

    /// @notice UnStZETA interface
    IUnStZETA public override unStZETA;

    /// @notice Current epoch
    uint256 public override currentEpoch;

    /// @notice Epoch delay period
    uint256 public override epochDelay;

    /// @notice Mapping of token to Array WithdrawRequest (one-to-many)
    /// @notice Withdrawal request structure
    /// amount2WithdrawFromStZETA: Amount to withdraw from stZETA in ZETA
    /// validatorNonce: Validator nonce
    /// requestEpoch: Epoch when the request was made
    /// validatorAddress: Validator address
    // struct RequestWithdraw {
    //     uint256 amount2WithdrawFromStZETA;
    //     uint256 validatorNonce;
    //     uint256 requestEpoch;
    //     address validatorAddress;
    // }
    // The second value represents the current unbond nonces for this user
    // The third value represents the current unbond epoch plus the withdrawalDelay, which is fixed at 2**13
    // There are two possible values here:
    // 1. In this case, validatorNonce and validatorAddress are 0, and amount2WithdrawFromStZETA has a value
    //    This case represents a withdrawal request that exceeds the staked amount and is reflected as reservedFunds
    //    RequestWithdraw(
    //         currentAmount2WithdrawInZETA,
    //         0,
    //         stakeManagerMem.epoch() + stakeManagerMem.withdrawalDelay(),
    //         address(0)
    //     )
    // 2. In this case, amount2WithdrawFromStZETA is 0, and validatorNonce and validatorAddress have values
    //    This case represents a withdrawal request that does not exceed the staked amount, and the corresponding information is updated in the validatorShare contract through the sellVoucher_new function
    //    RequestWithdraw(
    //         0,
    //         IValidatorShare(validatorShare).unbondNonces(address(this)),
    //         stakeManagerMem.epoch() + stakeManagerMem.withdrawalDelay(),
    //         validatorShare
    //     )
    mapping(uint256 => RequestWithdraw[]) public token2WithdrawRequests;

    /// @notice Token IDs for a specific epoch
    // Note that the first few epochs may have issues because they used the current epoch instead of current epoch + epochDelay
    mapping(uint256 => uint256[]) public epochsTokenIds;

    ////////////////////////////////////////////////////////////
    /////                                                    ///
    /////                   Functions                        ///
    /////                                                    ///
    ////////////////////////////////////////////////////////////

    /// @notice Prevents reentrancy attacks
    modifier nonReentrant() {
        _nonReentrant();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    /// @param _dao - Address of the DAO
    /// @param _insurance - Address of the insurance contract
    /// @param _oracle - Address of the oracle
    /// @param _nodeOperatorRegistry - Address of the node operator registry contract
    /// @param _unStZETA - Address of the UnStZETA contract
    /// @param _currentEpoch - Current epoch
    function initialize(
        address _dao,
        address _insurance,
        address _oracle,
        address _nodeOperatorRegistry,
        address _unStZETA,
        uint256 _currentEpoch
    ) external override initializer {
        // Initialize ACL, Pausable, ERC20
        __AccessControl_init_unchained();
        __Pausable_init_unchained();
        __ERC20_init_unchained("Staked ZETA", "stZETA");

        // Set roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(DAO, _dao);
        _grantRole(ORACLE_ROLE, _oracle);
        _grantRole(PAUSE_ROLE, msg.sender);
        _grantRole(UNPAUSE_ROLE, _dao);

        // Set contract addresses
        dao = _dao;
        insurance = _insurance;
        oracle = _oracle;
        nodeOperatorRegistry = INodeOperatorRegistry(_nodeOperatorRegistry);
        unStZETA = IUnStZETA(_unStZETA);

        // Set fee distribution
        entityFees = FeeDistribution(25, 50, 25);
        // Set threshold
        submitThreshold = 10 ** 10;
        // Set maximum submit threshold
        submitMaxThreshold = 10 ** 34;
        // Set protocol fee
        protocolFee = 10;
        // Set delegation lower bound
        delegationLowerBound = 0;
        // Set current epoch
        currentEpoch = _currentEpoch;
        // Set epoch delay
        epochDelay = 5;
        // New version number
        version = "1.0.2";
    }

    /// @notice Check if an address has ever staked
    function stakers(address _from) external view override returns (bool){
        return _stakers[_from];
    }

    /// @notice Send funds to the StZETA contract and mint StZETA tokens for msg.sender
    /// @return The amount of StZETA tokens generated
    function submit()
        external
        override
        payable
        whenNotPaused
        nonReentrant
        returns (uint256) {
        uint _amount = msg.value;
        // Check if the amount is greater than or equal to the submit threshold
        _require(_amount >= submitThreshold, "Invalid amount");
        // Check if the amount is less than or equal to the submit maximum threshold
        _require(_amount <= submitMaxThreshold, "Invalid amount");

        // Calculate the amount of stZETA tokens to mint based on the current exchange rate
        (uint256 amountToMint,,) = convertZETAToStZETA(_amount);

        // Check if the amount of stZETA tokens to mint is greater than 0
        _require(amountToMint > 0, "Mint ZERO");

        // Mint stZETA tokens by calling the _mint function of ERC20Upgradeable directly
        _mint(msg.sender, amountToMint);

        // Update totalBuffered by adding the submitted ZETA amount to it
        totalBuffered += _amount;

        // Emit the SubmitEvent event, defined in interfaces/IStZETA.sol
        emit SubmitEvent(msg.sender, _amount, balanceOf(msg.sender));

        // Return the amount of stZETA tokens minted
        return amountToMint;
    }

    /// @notice This function is used to calculate the amount of stZETA tokens to convert from ZETA
    /// @param _amountInZETA - The amount of ZETA tokens to convert to stZETA
    /// @return amountInStZETA - The amount of stZETA tokens to convert from ZETA
    /// @return totalStZETASupply - The total supply of stZETA tokens in the contract
    /// @return totalPooledZETA - The total amount of ZETA tokens in the staking pool
    function convertZETAToStZETA(uint256 _amountInZETA)
        public
        view
        override
        returns (
            uint256 amountInStZETA,
            uint256 totalStZETASupply,
            uint256 totalPooledZETA
        ) {
        // Get the total supply of stZETA tokens in the current contract, defined in ERC20Upgradeable
        totalStZETASupply = totalSupply();
        totalPooledZETA = getTotalPooledZETA();
        return (
            _convertZETAToStZETA(_amountInZETA, totalPooledZETA),
            totalStZETASupply,
            totalPooledZETA
        );
    }

    /// @notice This function is used to calculate the amount of ZETA tokens to convert from stZETA
    /// @param _amountInStZETA - The amount of stZETA tokens to convert to ZETA
    /// @return amountInZETA - The amount of ZETA tokens to convert from stZETA
    /// @return totalStZETAAmount - The total supply of stZETA tokens in the contract
    /// @return totalPooledZETA - The total amount of ZETA tokens in the staking pool
    function convertStZETAToZETA(uint256 _amountInStZETA)
        external
        view
        override
        returns (
            uint256 amountInZETA,
            uint256 totalStZETAAmount,
            uint256 totalPooledZETA
        ) {
        // total supply of stZETA tokens in the current contract, defined in ERC20Upgradeable
        totalStZETAAmount = totalSupply();
        totalPooledZETA = getTotalPooledZETA();
        return (
            _convertStZETAToZETA(_amountInStZETA, totalPooledZETA),
            totalStZETAAmount,
            totalPooledZETA
        );
    }

    /// @notice This function is used to calculate the total amount of ZETA in the pool
    /// @return Total pooled ZETA
    function getTotalPooledZETA() public view override returns (uint256) {
        // Get the total amount of ZETA staked in all validators
        uint256 staked = totalStaked();
        // Calculate the total amount of ZETA in the pool, which is the staked ZETA
        return _getTotalPooledZETA(staked);
    }

    /// @notice This function is used to calculate the total amount of ZETA in the pool, which is the staked ZETA
    /// @return The total amount of ZETA staked in all validators
    /// 
    function totalStaked() public view override returns (uint256){
        // This is the final total stake of ZETA to be returned
        uint256 totalStake;
        // Get all node operators
        INodeOperatorRegistry.ValidatorData[] memory nodeOperators = nodeOperatorRegistry.listWithdrawNodeOperators();

        // Calculate the total stake of all node operators, iterate through all node operators
        for (uint256 i = 0; i < nodeOperators.length; i++) {
            // Get the validator operator of the current node operator's validator
            IValidatorOperator validatorOperator = IValidatorOperator(nodeOperators[i].operatorAddress);

            // Accumulate the stake amount of the current node operator's validator operator
            totalStake += validatorOperator.totalStake();
        }

        return totalStake;
    }


    // Calculate the total amount of ZETA based on the total stake
    function _getTotalPooledZETA(uint256 _totalStaked)
        private
        view
        returns (uint256) {
        // This is divided into 4 parts
        // 1. totalstaked: The total amount of ZETA staked in all node operators
        // 2. totalBuffered: The total amount of ZETA buffered in the contract, which is the amount of ZETA submitted by users
        // 3. calculatePendingBufferedTokens(): Calculate the total amount stored in the stZETAWithdrawRequest array
        // 4. reservedFunds: The reserved funds in the contract
        // It represents the sum of all staked ZETA + all submitted but not delegated ZETA + all requested withdrawal amounts - reserved funds
        return
            _totalStaked +
            totalBuffered +
            calculatePendingBufferedTokens() -
            reservedFunds;
    }

    /// @notice Calculates the total amount stored in the stZETAWithdrawRequest array.
    /// @return pendingBufferedTokens The total amount of stZETA pending for processing.
    function calculatePendingBufferedTokens()
        public
        pure
        override
        returns (uint256 pendingBufferedTokens) {
        // Currently returns 0, needs to be modified later
        return 0;
    }

    /// @notice This function is used to calculate the amount of stZETA obtained by converting ZETA.
    /// @param _ZETAAmount - The amount of ZETA to convert to stZETA.
    /// @return amountInStZETA, totalStZETAAmount, and totalPooledZETA
    function _convertZETAToStZETA(uint256 _ZETAAmount, uint256 _totalPooledZETA) 
        private view returns (uint256) {
        // totalSupply() is a function of Erc20Upgradeable that returns the total supply of stZETA
        uint256 totalStZETASupply = totalSupply();
        // This is mainly for handling the initial case
        // If totalStZETASupply is 0, it is set to 1. totalStZETASupply is the total amount of stZETA in the contract
        totalStZETASupply = totalStZETASupply == 0 ? 1 : totalStZETASupply;
        // If _totalPooledZETA is 0, it is set to 1. _totalPooledZETA is the total buffered ZETA in the contract
        _totalPooledZETA = _totalPooledZETA == 0 ? 1 : _totalPooledZETA;

        // The core calculation part
        // amountInStZETA is the amount of ZETA to be converted to stZETA
        // The calculation formula is:
        // stZETA amount = (_ZETAAmount * totalStZETASupply) / _totalPooledZETA
        uint256 amountInStZETA = (_ZETAAmount * totalStZETASupply) /
            _totalPooledZETA;

        // Returns the amount of ZETA to be converted to stZETA
        return amountInStZETA;
    }

    /// @notice This function is used to calculate the amount of ZETA obtained by converting stZETA.
    /// @param _stZETAAmount - The amount of stZETA to convert to ZETA.
    /// @return amountInZETA, totalStZETAAmount, and totalPooledZETA
    function _convertStZETAToZETA(uint256 _stZETAAmount, uint256 _totalPooledZETA) private view returns (uint256) {
        // totalSupply() is a function of Erc20Upgradeable that returns the total supply of stZETA
        uint256 totalStZETASupply = totalSupply();
        // This is mainly for handling the initial case
        totalStZETASupply = totalStZETASupply == 0 ? 1 : totalStZETASupply;
        _totalPooledZETA = _totalPooledZETA == 0 ? 1 : _totalPooledZETA;
        // The core calculation part
        // amountInZETA is the amount of ZETA to be converted from stZETA
        // The calculation formula is:
        // ZETA amount = (_stZETAAmount * _totalPooledZETA) / totalStZETASupply
        uint256 amountInZETA = (_stZETAAmount * _totalPooledZETA) /
            totalStZETASupply;
        // Returns the amount of stZETA to be converted to ZETA
        return amountInZETA;
    }

    /// @notice This will be included in the cron job and can only be called by ORACLE_ROLE.
    /// @notice Delegate tokens to the validator share contract.
    function delegate() external override whenNotPaused nonReentrant onlyRole(ORACLE_ROLE) {
        // Store totalBuffered and reservedFunds temporarily
        uint256 ltotalBuffered = totalBuffered;
        uint256 lreservedFunds = reservedFunds;
        // Check if totalBuffered is greater than delegationLowerBound + reservedFunds
        _require(
            ltotalBuffered > delegationLowerBound + lreservedFunds,
            "Amount lower than minimum"
        );
        // Check if the balance of the current contract is greater than totalBuffered
        _require(
            address(this).balance >= ltotalBuffered,
            "Balance lower than Buffered"
        );

        // The total amount to delegate is equal to totalBuffered - reservedFunds
        uint256 amountToDelegate = ltotalBuffered - lreservedFunds;
        
        // Get the stake information of all active node operators
        /// @notice Calculate how total buffered should be distributed among active validators, depending on whether the system is balanced
        /// If validators are in the EJECTED or UNSTAKED state, this function will revert
        /// @return validators All active node operators
        /// @return stakePerOperator The stake amount per node
        /// @return operatorRatios The ratio list for each node operator
        /// @return totalRatio The total ratio
        /// @return totalStaked The total stake amount
        /// ValidatorData is defined in interfaces/INodeOperatorRegistry.sol
        /// @notice Data structure for node operators
        /// @param operatorAddress The validator's validator operator address
        /// @param delegateAddress The validator's delegation address
        /// @param rewardAddress The validator's reward address
        /// struct ValidatorData {
        ///     address operatorAddress;
        ///     address delegateAddress;
        ///     address rewardAddress;
        /// }
        (
            INodeOperatorRegistry.ValidatorData[] memory validators,
            ,
            uint256[] memory operatorRatios,
            uint256 totalRatio,
        ) = nodeOperatorRegistry.getValidatorsDelegationAmount();
        // Get the length of validators
        uint256 validatorsOperatorLength = validators.length;
        // Remainder, the remaining amount of money
        uint256 remainder;
        // Actual delegated amount
        uint256 amountDelegated;
        // Temporary variable for the amount delegated by the validator used
        uint256 validatorAmountDelegated;
        // Iterate through all validators
        for (uint256 i = 0; i < validatorsOperatorLength; i++) {
            // Get the current validator's ratio
            uint256 operatorRatio = operatorRatios[i];
            // Calculate the delegated amount for the current validator
            validatorAmountDelegated = (amountToDelegate * operatorRatio) / totalRatio;
            // If the delegated amount for the current validator is 0, skip
            if (validatorAmountDelegated == 0) continue;
            // Delegate the tokens
            IValidatorOperator(validators[i].operatorAddress).delegate{value: validatorAmountDelegated}();
            // Update the actual delegated amount
            amountDelegated += validatorAmountDelegated;
        }
        // Remainder, which is the remaining amount of money, is the total amount to delegate minus the actual delegated amount
        remainder = amountToDelegate - amountDelegated;
        // Set the totalBuffered as the remainder plus reservedFunds
        totalBuffered = remainder + lreservedFunds;
        // Emit the event
        emit DelegateEvent(amountDelegated, remainder);
    }

    /// @notice This function is used to store the user's withdrawal request in the RequestWithdraw structure
    /// One thing to note here is that the user has just submitted ZETA and minted StZETA, but the Oracle has not delegated StZETA to the validator
    /// @param _amount - The amount of StZETA to request withdrawal
    /// @return NFT token id.
    function requestWithdraw(uint256 _amount)
        external
        override
        whenNotPaused
        nonReentrant
        returns (uint256) {
        // Check if the amount of stZETA is greater than 0 and if the sender's balance is greater than or equal to the amount
        _require(
            _amount > 0 && balanceOf(msg.sender) >= _amount,
            "Invalid amount"
        );
        // NFT id
        uint256 tokenId;

        // Create a separate scope to resolve "stack too deep" error
        {
            // Get the total amount of ZETA in the pool, including staked, buffered, reserved funds, and future withdrawal requests
            uint256 totalPooledZETA = getTotalPooledZETA();
            // Convert the amount of stZETA to ZETA
            uint256 totalAmount2WithdrawInZETA = _convertStZETAToZETA(
                _amount, totalPooledZETA
            );
            // Check if the amount of ZETA to withdraw is greater than 0
            _require(totalAmount2WithdrawInZETA > 0, "Withdraw 0 Zeta");
            // Get data of active node operators
            // This should be getting data of candidate withdrawal validators
            (
                INodeOperatorRegistry.ValidatorData[] memory activeNodeOperators,
                uint256 totalDelegated,
                ,
                ,
                ,
                uint256 totalValidatorsToWithdrawFrom,
                uint256 minStakeAmount
            ) = nodeOperatorRegistry.getValidatorsRequestWithdraw(totalAmount2WithdrawInZETA);
            
            // Ensure that the amount of ZETA to withdraw is less than or equal to totalDelegated + localActiveBalance
            // This means that the amount of ZETA the user wants to withdraw cannot exceed the total ZETA in the system
            {
                // Temporary variables for totalBuffered and reservedFunds
                uint256 totalBufferedMem = totalBuffered;
                uint256 reservedFundsMem = reservedFunds;
                // Local available balance
                // This is the ZETA amount after deducting reserved funds
                // The formula below means that if totalBuffered is greater than reservedFunds, localActiveBalance is equal to totalBuffered - reservedFunds, otherwise it is 0
                uint256 localActiveBalance = totalBufferedMem > reservedFundsMem
                    ? totalBufferedMem - reservedFundsMem
                    : 0;
                // Check if the total amount of ZETA to withdraw is greater than or equal to totalDelegated + localActiveBalance
                uint256 liquidity = totalDelegated + localActiveBalance;
                // If the amount of ZETA to withdraw is greater than or equal to totalDelegated, throw an error, indicating that the user wants to withdraw more ZETA than the system has
                _require(
                    liquidity >= totalAmount2WithdrawInZETA,
                    "Too much withdraw"
                );
            }

            // Added a scope to fix "stack too deep" error
            {
                // Temporary variable to store the remaining amount of ZETA to withdraw
                uint256 currentAmount2WithdrawInZETA = totalAmount2WithdrawInZETA;
                // Create an NFT for the user
                tokenId = unStZETA.mint(msg.sender);
                // If totalDelegated is not 0 and minStakeAmount is not 0, meaning there are delegates
                if ((totalDelegated != 0) && (minStakeAmount * totalValidatorsToWithdrawFrom) != 0) {
                    // Currently only considering balanced state
                    // If the number of validators to withdraw is not 0, meaning the system is balanced
                    // Request withdrawal in balanced state, where each validator has the same amount, so there won't be a case where the average amount is not enough
                    // The calculation in nodeOperatorRegistry.getValidatorsRequestWithdraw ensures that the average distribution is correct
                    currentAmount2WithdrawInZETA = _requestWithdrawBalanced(
                        tokenId,
                        activeNodeOperators,
                        totalAmount2WithdrawInZETA,
                        totalValidatorsToWithdrawFrom,
                        totalDelegated,
                        currentAmount2WithdrawInZETA,
                        minStakeAmount
                    );
                }
                // For the part greater than minAmount * totalValidatorsToWithdrawFrom, use reservedFunds
                if (totalAmount2WithdrawInZETA > (minStakeAmount * totalValidatorsToWithdrawFrom)) {
                    uint256 amountGap = totalAmount2WithdrawInZETA - (minStakeAmount * totalValidatorsToWithdrawFrom);
                    /// @notice RequestWithdraw struct.
                    /// @param amount2WithdrawFromStZETA Amount in ZETA.
                    /// @param validatorNonce Validator nonce.
                    /// @param requestEpoch Epoch at the time of request.
                    /// @param validatorAddress Validator address.
                    // struct RequestWithdraw {
                    //     uint256 amount2WithdrawFromStZETA;
                    //     uint256 validatorNonce;
                    //     uint256 requestEpoch;
                    //     address validatorAddress;
                    // }
                    // The second one represents the nonces for this user's current unbonding
                    // The third one represents the current epoch of this user's unbonding plus the withdrawalDelay, which is fixed
                    token2WithdrawRequests[tokenId].push(
                        RequestWithdraw(
                            amountGap,
                            0,
                            currentEpoch + epochDelay,
                            address(0)
                        )
                    );
                    // reservedFunds is the amount of ZETA reserved in the contract, which means that this part of ZETA is reserved in the contract for the user to withdraw later
                    // That is to say, this part is the remaining ZETA after the user can unbond
                    reservedFunds += amountGap;
                    currentAmount2WithdrawInZETA = 0;
                }
            }
            // Burn the user's stZETA
            _burn(msg.sender, _amount);
        }
        // Add the mapping of epoch -> tokenId
        // Note that the first few epochs may have issues because they used the current epoch instead of current epoch + epochDelay
        epochsTokenIds[currentEpoch+epochDelay].push(tokenId);
        // emit RequestWithdrawEvent(msg.sender, _amount, tokenId, balanceOf(msg.sender));
        emit RequestWithdrawEvent(msg.sender, _amount, tokenId, balanceOf(msg.sender));
        return tokenId;
    }

    /// @notice Request withdrawal when the system is balanced, where balance means an equal number of validators, so there won't be a shortage of the average number
    /// @param tokenId - NFT token id
    /// @param activeNodeOperators - Active node operators data
    /// @param totalAmount2WithdrawInZETA - Total amount of ZETA to withdraw
    /// @param totalValidatorsToWithdrawFrom - Total number of validators to withdraw from
    /// @param totalDelegated - Total amount of delegated ZETA
    /// @param currentAmount2WithdrawInZETA - Current amount of ZETA to withdraw
    /// @param minStakeAmount - Minimum stake amount for validators
    function _requestWithdrawBalanced(
        uint256 tokenId,
        INodeOperatorRegistry.ValidatorData[] memory activeNodeOperators,
        uint256 totalAmount2WithdrawInZETA,
        uint256 totalValidatorsToWithdrawFrom,
        uint256 totalDelegated,
        uint256 currentAmount2WithdrawInZETA,
        uint256 minStakeAmount
    ) private returns (uint256) {
        // // In theory, currentAmount2WithdrawInZETA is equal to totalAmount2WithdrawInZETA
        // // The total amount to withdraw is the minimum of totalDelegated and totalAmount2WithdrawInZETA
        // // Which means only the total staked ZETA can be withdrawn at most
        // uint256 totalAmount = min(totalDelegated, totalAmount2WithdrawInZETA);
        // // The amount of ZETA to withdraw from each validator is totalAmount/totalValidatorsToWithdrawFrom, evenly distributed
        // // This is ensured when calling nodeOperatorRegistry.getValidatorsRequestWithdraw
        // uint256 amount2WithdrawFromValidator = totalAmount /
        //     totalValidatorsToWithdrawFrom;

        // Calculate the amount of ZETA to withdraw from each node directly based on minStakeAmount
        // Compare the total amount of ZETA to withdraw calculated based on the minimum stake amount and the current amount of ZETA to withdraw, take the minimum value
        // Which means only the ZETA equivalent to the minimum stake amount of each node can be withdrawn at most
        uint256 totalAmount = min(minStakeAmount * totalValidatorsToWithdrawFrom, totalAmount2WithdrawInZETA);
        totalAmount = min(totalDelegated, totalAmount);
        // The amount of ZETA to withdraw from each validator is totalAmount/totalValidatorsToWithdrawFrom, evenly distributed
        uint256 amount2WithdrawFromValidator = totalAmount / totalValidatorsToWithdrawFrom;
        // Iterate over totalValidatorsToWithdrawFrom validators
        for (uint256 idx = 0; idx < totalValidatorsToWithdrawFrom; idx++) {
            // Get the validator
            IValidatorOperator validatorOperator = IValidatorOperator(activeNodeOperators[idx].operatorAddress);
            // Require the validator's stake amount to be greater than or equal to the minimum stake amount
            _require(validatorOperator.totalStake() >= amount2WithdrawFromValidator, "stake too low");
            /// @notice Call the validator's withdraw method, update the validator's internal unbond content
            /// Insert the information into token2WithdrawRequests, and update the returned currentAmount2WithdrawInZETA by subtracting the amount of ZETA withdrawn in this request
            currentAmount2WithdrawInZETA = _requestWithdraw(
                tokenId,
                validatorOperator,
                amount2WithdrawFromValidator,
                currentAmount2WithdrawInZETA
            );
        }
        // Return the remaining amount of ZETA to withdraw
        return currentAmount2WithdrawInZETA;
    }

    /// @notice Call the unstake method of the validator to update the unbond content inside the validator
    /// Insert the information into token2WithdrawRequests and update the currentAmount2WithdrawInZETA by subtracting the amount2WithdrawFromValidator
    /// @param tokenId - NFT token id
    /// @param validatorOperator - validatorOperator contract interface
    /// @param amount2WithdrawFromValidator - The amount of ZETA to withdraw
    /// @param currentAmount2WithdrawInZETA - The current total amount of ZETA to withdraw
    /// @return The remaining amount of ZETA to withdraw
    function _requestWithdraw(
        uint256 tokenId,
        IValidatorOperator validatorOperator,
        uint256 amount2WithdrawFromValidator,
        uint256 currentAmount2WithdrawInZETA
    ) private returns (uint256) {
        /// @notice This is an API to delegate selling vouchers from validatorShare
        /// Call the sellVoucher_new function of ValidatorShare to unstake and update the unbond content inside
        /// @param _validatorShare - The address of the validatorShare contract
        /// @param _claimAmount - The amount of ZETA to withdraw
        /// @param _maximumSharesToBurn - The maximum shares to burn
        // Unstake and update the unbond content inside the validator
        validatorOperator.unStake(amount2WithdrawFromValidator);
        /// @notice Request withdraw struct.
        /// @param amount2WithdrawFromStZETA - The amount in ZETA to withdraw.
        /// @param validatorNonce - The validator nonce.
        /// @param requestEpoch - The epoch when the request is made.
        /// @param validatorAddress - The validator address.
        // struct RequestWithdraw {
        //     uint256 amount2WithdrawFromStZETA;
        //     uint256 validatorNonce;
        //     uint256 requestEpoch;
        //     address validatorAddress;
        // }
        // The second parameter represents the current nonces for this user's unbond
        // The third parameter represents the current epoch plus the withdrawalDelay, which is fixed at 2**13
        token2WithdrawRequests[tokenId].push(
            RequestWithdraw(
                0,
                validatorOperator.getUnbondNonces(address(this)),
                currentEpoch + epochDelay,
                address(validatorOperator)
            )
        );
        // Update the current amount of ZETA to withdraw by subtracting the amount withdrawn in this request
        currentAmount2WithdrawInZETA -= amount2WithdrawFromValidator;
        // Return the remaining amount of ZETA to withdraw
        return currentAmount2WithdrawInZETA;
    }

    /**
     * @dev Hook that is called before any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * will be transferred to `to`.
     * - when `from` is zero, `amount` tokens will be minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens will be burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _beforeTokenTransfer(address, address to, uint256) internal override {
        // Check if this user has ever minted before, if not, increase totalStakers by 1 and add this user to _stakers
        if (!_stakers[to]) {
            totalStakers += 1;
            _stakers[to] = true;
        }
    }

    /// @notice Get the tokenIds for a specific epoch
    /// @param epoch Epoch
    /// @return tokenIds
    function getEpochsTokenIds(uint256 epoch) external view override returns (uint256[] memory) {
        return epochsTokenIds[epoch];
    }

    /// @notice Get all requestWithdraw information for a specific epoch
    /// @param epoch Epoch
    /// @return requestWithdrawsQuery list
    function getEpochsRequestWithdraws(uint256 epoch) 
        external view override returns (RequestWithdrawQuery[] memory) {
        // First, get all tokenIds
        uint256[] memory tokenIds = epochsTokenIds[epoch];
        return _getRequestWithdrawQuerysByTokenIds(tokenIds);
    }

    /// @notice Get all requestWithdraw information for a specific address
    /// @param target_address Target address
    /// @return requestWithdrawsQuery list
    function getAddressRequestWithdraws(address target_address) 
        external view override returns (RequestWithdrawQuery[] memory) {
        // First, get all tokenIds
        uint256[] memory tokenIds = unStZETA.getOwnedTokens(target_address);
        return _getRequestWithdrawQuerysByTokenIds(tokenIds);
    }

    /// @notice Get the requestWithdrawQuery list corresponding to a list of tokenIds
    /// @param tokenIds List of tokenIds
    /// @return requestWithdrawQuerys list
    function _getRequestWithdrawQuerysByTokenIds(uint256[] memory tokenIds) 
        internal view returns (RequestWithdrawQuery[] memory) {
        uint256 tokenIdsLength = tokenIds.length;
        uint256 tokenId;
        uint256 requestTotalLength;
        // Get the total length of requests for all tokenIds
        RequestWithdraw memory requestWithdrawItem;
        for (uint256 i = 0; i < tokenIdsLength; i++) {
            tokenId = tokenIds[i];
            requestTotalLength += token2WithdrawRequests[tokenId].length;
        }
        // Create the return array
        // @notice Struct for querying withdrawal.
        // @param amount Amount in ZETA.
        // @param tokenId TokenId.
        // @param validatorNonce Validator nonce.
        // @param requestEpoch Epoch when the request was made.
        // @param validatorAddress Validator shared address.
        // struct RequestWithdrawQuery {
        //     uint256 amount;
        //     uint256 tokenId;
        //     uint256 validatorNonce;
        //     uint256 requestEpoch;
        //     address validatorAddress;
        // }
        IValidatorOperator.DelegatorUnbond memory delegatorUnbond;
        RequestWithdrawQuery[] memory requestWithdrawQuerys = new RequestWithdrawQuery[](requestTotalLength);
        uint256 requestWithdrawQuerysIndex = 0;
        // Iterate through all tokenIds
        for (uint256 i = 0; i < tokenIdsLength; i++) {
            tokenId = tokenIds[i];
            // Iterate through all requests
            for (uint256 j = 0; j < token2WithdrawRequests[tokenId].length; j++) {
                requestWithdrawItem = token2WithdrawRequests[tokenId][j];
                // If it is reserved
                if (requestWithdrawItem.validatorAddress == address(0)) {
                    requestWithdrawQuerys[requestWithdrawQuerysIndex] = RequestWithdrawQuery(
                        requestWithdrawItem.amount2WithdrawFromStZETA,
                        tokenId,
                        requestWithdrawItem.validatorNonce,
                        requestWithdrawItem.requestEpoch,
                        requestWithdrawItem.validatorAddress
                    );
                } else {
                    // Get the unbond information of the validator
                    delegatorUnbond = IValidatorOperator(requestWithdrawItem.validatorAddress).getDelegatorUnbond(address(this), requestWithdrawItem.validatorNonce);
                    requestWithdrawQuerys[requestWithdrawQuerysIndex] = RequestWithdrawQuery(
                        delegatorUnbond.amount,
                        tokenId,
                        requestWithdrawItem.validatorNonce,
                        delegatorUnbond.withdrawEpoch,
                        requestWithdrawItem.validatorAddress
                    );
                }
                requestWithdrawQuerysIndex += 1;
            }
        }
        return requestWithdrawQuerys;
    }

    /// @notice Get the epoch corresponding to a specific tokenId
    /// @param tokenId The target tokenId
    /// @return requestWithdrawsQuery list
    function getTokenIdEpoch(uint256 tokenId) 
        external view override returns (uint256) {
        return token2WithdrawRequests[tokenId][0].requestEpoch;
    }

    function getTokenIdRequestWithdraws(uint256 tokenId) 
        external view returns (RequestWithdraw[] memory) {
        return token2WithdrawRequests[tokenId];
    }

    /// @notice Receive ZETA
    function receiveZETA() external payable override {
        // Check if msg.value is greater than 0
        _require(msg.value > 0, "Invalid amount");
        // Emit event
        emit ReceiveZETAEvent(msg.sender, msg.value);
    }

    function min(uint256 _valueA, uint256 _valueB) private pure returns(uint256) {
        return _valueA > _valueB ? _valueB : _valueA;
    }

    // Ensure non-reentrancy
    function _nonReentrant() private view {
        _require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
    }

    // Ensure condition is met
    function _require(bool _condition, string memory _message) private pure {
        require(_condition, _message);
    }

    /// @notice Pauses the contract
    function pause() external onlyRole(PAUSE_ROLE) {
        _pause();
    }

    /// @notice Unpauses the contract
    function unpause() external onlyRole(UNPAUSE_ROLE) {
        _unpause();
    }

    /// @notice Get the version of each update
    function getUpdateVersion() external pure override returns(string memory) {
        return "1.0.2.5";
    }

    /// @notice claim multi tokens
    /// @param _tokenIds - the tokenIds of the NFT
    /// @return totalAmountToClaim - the total amount of ZETA to claim
    function claimMultiTokens(uint256[] memory _tokenIds) 
        external override whenNotPaused nonReentrant returns(uint256) {
        uint256 length = _tokenIds.length;
        uint256 totalAmountToClaim;
        for (uint256 idx = 0; idx < length; idx++) {
            totalAmountToClaim += _claimTokens(_tokenIds[idx]);
        }

        return totalAmountToClaim;
    }
    
    /// @notice Claims tokens
    function _claimTokens(uint256 _tokenId) private returns(uint256) {
        // Check if msg.sender is the owner of the tokenId
        _require(unStZETA.isApprovedOrOwner(msg.sender, _tokenId), "Not owner");
        // List of withdrawal requests to be processed
        RequestWithdraw[] memory usersRequest = token2WithdrawRequests[_tokenId];
        // Check if the current epoch is greater than or equal to the user's request epoch
        _require(currentEpoch >= usersRequest[0].requestEpoch, "Epoch early");
        // Burn the user's NFT
        unStZETA.burn(_tokenId);
        // Delete the user's withdrawal request mapping
        delete token2WithdrawRequests[_tokenId];
        // Remove this tokenId from the tokenIds in the epoch
        _deleteEpochsTokenId(usersRequest[0].requestEpoch, _tokenId);

        uint256 length = usersRequest.length;
        uint256 amountToClaim;
        uint256 _amountToClaim;

        // Iterate through the list of withdrawal requests to be processed
        for (uint256 idx = 0; idx < length; idx++) {
            // If the validator address is not equal to 0, it means it is extracted from the validator
            if (usersRequest[idx].validatorAddress != address(0)) {
                // Extract based on the unbond information, which will transfer the corresponding funds back and return the amount of funds transferred
                _amountToClaim = unstakeClaimTokens(
                    usersRequest[idx].validatorAddress,
                    usersRequest[idx].validatorNonce
                );
                amountToClaim += _amountToClaim;
            } else {
                // Otherwise, it means it is to be extracted from the reserved funds
                _amountToClaim = usersRequest[idx].amount2WithdrawFromStZETA;
                // Update state variables
                // Subtract the amount of ZETA to be withdrawn from the reserved funds
                reservedFunds -= _amountToClaim;
                // Subtract the amount of ZETA to be withdrawn from the totalBuffered
                totalBuffered -= _amountToClaim;
                // Add the amount of ZETA to be withdrawn to amountToClaim
                amountToClaim += _amountToClaim;
            }
        }
        // Transfer to the user
        (bool success, ) = payable(msg.sender).call{value: amountToClaim}("");
        // Check if the transfer is successful
        _require(success, "Transfer failed");
        // Emit the ClaimTokensEvent event
        emit ClaimTokensEvent(msg.sender, _tokenId, amountToClaim);

        return amountToClaim;
    }

    /// @notice delete target tokenId from epochsTokenIds
    /// @param epoch - epoch
    /// @param tokenId - tokenId
    function _deleteEpochsTokenId(uint256 epoch, uint256 tokenId) internal {
        uint256[] storage tokenIds = epochsTokenIds[epoch];
        uint256 tokenIdsLength = tokenIds.length;
        for (uint256 i = 0; i < tokenIdsLength; i++) {
            if (tokenIds[i] == tokenId) {
                tokenIds[i] = tokenIds[tokenIdsLength - 1];
                tokenIds.pop();
                break;
            }
        }
    }

    /// @notice API to unstake claim from validatorShare
    /// @param _validatorAddress - validator address
    /// @param _unbondNonce - unbond nonce
    function unstakeClaimTokens(address _validatorAddress, uint256 _unbondNonce) private returns(uint256) {
        // according to unbond information to claim, return the amount of funds transferred back
        return IValidatorOperator(_validatorAddress).unstakeClaimTokens(_unbondNonce);
    }

    /// @notice get the valid last epoch tokenId
    function getValidEpoch() external view returns(uint256) {
        // Iterate through all validator to get smallest epoch
        uint256 smallestEpoch = type(uint256).max;
        INodeOperatorRegistry.ValidatorData[] memory validators = nodeOperatorRegistry.listDelegatedNodeOperators();
        uint256 validatorsLength = validators.length;
        uint256 lastEpochFinishedUnbond;
        for (uint256 idx = 0; idx < validatorsLength; idx++) {
            lastEpochFinishedUnbond = IValidatorOperator(validators[idx].operatorAddress).lastEpochFinishedUnbond();
            if (lastEpochFinishedUnbond < smallestEpoch) {
                smallestEpoch = lastEpochFinishedUnbond;
            }
        }
        return smallestEpoch;
    }


    ////////////////////////////////////////////////////////////
    /////                                                    ///
    /////                    Setters                         ///
    /////                                                    ///
    ////////////////////////////////////////////////////////////

    /// @notice Set new fees
    /// @notice Only DAO role can call this function.
    /// @param _daoFee - DAO fee in %
    /// @param _operatorsFee - Operator fees in %
    /// @param _insuranceFee - Insurance fee in %
    function setFees(uint8 _daoFee, uint8 _operatorsFee, uint8 _insuranceFee) external override onlyRole(DAO) {
        // Check if the sum of fees is equal to 100
        _require(
            _daoFee + _operatorsFee + _insuranceFee == 100,
            "sum(fee)!=100"
        );
        entityFees.dao = _daoFee;
        entityFees.operators = _operatorsFee;
        entityFees.insurance = _insuranceFee;

        emit SetFees(_daoFee, _operatorsFee, _insuranceFee);
    }

    /// @notice Set new DAO address.
    /// @notice Only DAO role can call this function.
    /// @param _newDAO - New DAO address.
    function setDaoAddress(address _newDAO) external override onlyRole(DAO) {
        address oldDAO = dao;
        dao = _newDAO;
        emit SetDaoAddress(oldDAO, _newDAO);
    }

    /// @notice Set a new Oracle address.
    /// @notice Only the DAO role can call this function.
    /// @param _newOracle - The new Oracle address.
    function setOracleAddress(address _newOracle) external override onlyRole(DAO) {
        address oldOracle = oracle;
        oracle = _newOracle;
        emit SetOracleAddress(oldOracle, _newOracle);
    }

    /// @notice Set a new protocol fee.
    /// @param _newProtocolFee - The new protocol fee, in percentage.
    function setProtocolFee(uint8 _newProtocolFee)
        external
        override
        onlyRole(DAO) {
        // Check if the protocol fee is greater than 0 and less than or equal to 100
        _require(
            _newProtocolFee > 0 && _newProtocolFee <= 100,
            "Invalid protocol fee"
        );
        uint8 oldProtocolFee = protocolFee;
        protocolFee = _newProtocolFee;

        emit SetProtocolFee(oldProtocolFee, _newProtocolFee);
    }

    /// @notice Set a new insurance address.
    /// @notice Only the DAO role can call this function.
    /// @param _address - The new insurance address.
    function setInsuranceAddress(address _address)
        external
        override
        onlyRole(DAO) {
        insurance = _address;
        emit SetInsuranceAddress(_address);
    }

    /// @notice Set a new version.
    /// @param _newVersion - The new contract version.
    function setVersion(string calldata _newVersion)
        external
        override
        onlyRole(DAO) {
        emit Version(version, _newVersion);
        version = _newVersion;
    }

    /// @notice Set a new submit threshold.
    /// @notice Only the DAO role can call this function.
    /// @param _newSubmitThreshold - The new submit threshold.
    function setSubmitThreshold(uint256 _newSubmitThreshold) 
        external
        override
        onlyRole(DAO) {
        uint256 oldSubmitThreshold = submitThreshold;
        submitThreshold = _newSubmitThreshold;
        emit SetSubmitThreshold(oldSubmitThreshold, _newSubmitThreshold);
    }

    /// @notice Set a new APR.
    /// @notice Only the ORACLE_ROLE can call this function.
    /// @param _newApr - The new APR.
    function setApr(uint16 _newApr) 
        external
        override
        onlyRole(ORACLE_ROLE) {
        uint16 oldApr = apr;
        apr = _newApr;
        emit SetApr(oldApr, _newApr);
    }

    // @notice This function is used to set a new delegation lower bound.
    /// @notice Only the DAO can call this function.
    /// @param _delegationLowerBound - The new delegation lower bound.
    function setDelegationLowerBound(uint256 _delegationLowerBound)
        external
        override
        onlyRole(DAO) {
        delegationLowerBound = _delegationLowerBound;
        emit SetDelegationLowerBound(_delegationLowerBound);
    }

    /// @notice This function is used to set a new node operator registry address.
    /// @notice Only the DAO can call this function.
    /// @param _address - The new node operator registry address.
    function setNodeOperatorRegistryAddress(address _address)
        external
        override
        onlyRole(DAO) {
        nodeOperatorRegistry = INodeOperatorRegistry(_address);
        emit SetNodeOperatorRegistryAddress(_address);
    }

    /// @notice Set a new submit max threshold.
    /// @notice Only the DAO can call this function.
    /// @param _newSubmitMaxThreshold - The new submit max threshold.
    function setSubmitMaxThreshold(uint256 _newSubmitMaxThreshold) 
        external
        override
        onlyRole(DAO) {
        uint256 oldSubmitMaxThreshold = submitMaxThreshold;
        submitMaxThreshold = _newSubmitMaxThreshold;
        emit SetSubmitMaxThreshold(oldSubmitMaxThreshold, _newSubmitMaxThreshold);
    }

    /// @notice This function is used to set a new UnStZETA address.
    /// @notice Only the DAO can call this function.
    /// @param _address - The new UnStZETA address.
    function setUnStZETA(address _address)
        external
        override
        onlyRole(DAO) {
        unStZETA = IUnStZETA(_address);
        emit SetUnStZETAAddress(_address);
    }

    /// @notice Allows setting a new current epoch
    /// @notice Only the ORACLE_ROLE role can call this function.
    /// @param _newCurrentEpoch new CurrentEpoch.
    function setCurrentEpoch(uint256 _newCurrentEpoch) 
        external
        override
        onlyRole(ORACLE_ROLE) {
        uint256 oldCurrentEpoch = currentEpoch;
        currentEpoch = _newCurrentEpoch;
        emit SetCurrentEpoch(oldCurrentEpoch, _newCurrentEpoch);
    }

    /// @notice Allows setting a new epoch delay
    /// @notice Only the DAO role can call this function.
    /// @param _newEpochDelay new EpochDelay
    function setEpochDelay(uint256 _newEpochDelay)
        external
        override
        onlyRole(DAO) {
        uint256 oldEpochDelay = epochDelay;
        epochDelay = _newEpochDelay;
        emit SetEpochDelay(oldEpochDelay, _newEpochDelay);
    }

    /// @notice Adjusts the epoch for the tokenId list
    /// @param tokenIds Target tokenIds
    /// @param targetEpoch Target epoch
    function setTokenIdsEpoch(uint256[] memory tokenIds, uint256 targetEpoch) 
        external override onlyRole(DAO) {
        // Iterate through all tokenIds
        for (uint256 i = 0; i < tokenIds.length; i++) {
            // Iterate through all requests
            for (uint256 j = 0; j < token2WithdrawRequests[tokenIds[i]].length; j++) {
                token2WithdrawRequests[tokenIds[i]][j].requestEpoch = targetEpoch;
            }
        }
        emit SetTokenIdsEpoch(tokenIds, targetEpoch);
    }

}