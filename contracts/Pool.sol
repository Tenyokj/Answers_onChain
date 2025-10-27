// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title Pool — Fund storage and distribution contract
 * @author Tenyokj
 * @notice This contract safely stores ETH deposits and stakes from the Answers contract.
 * @dev Only the linked Answers contract can call deposit or payout functions.
 *      Pool is a "vault" that prevents reentrancy and enforces payout rules for all scenarios:
 *      ACCEPT, REJECT, and TIMEOUT.
 */
contract Pool is ReentrancyGuard {
    /// @notice Owner address — can link the Answers contract
    address public owner;

    /// @notice Address of the linked Answers contract
    address public answersContract;

    // ============================================================
    //                      BALANCES
    // ============================================================

    /// @notice Mapping: questionId => deposit amount from asker (Vanя)
    mapping(bytes32 => uint256) public questionBalance;

    /// @notice Mapping: answerId => stake amount from responder (Dимa)
    mapping(bytes32 => uint256) public stakeBalance;

    // ============================================================
    //                      EVENTS
    // ============================================================

    /// @notice Emitted when an asker deposits ETH for a new question
    event DepositedQuestion(bytes32 indexed questionId, uint256 amount);

    /// @notice Emitted when a responder deposits their ETH stake
    event DepositedStake(bytes32 indexed answerId, uint256 amount);

    /// @notice Emitted when payout occurs after answer acceptance
    event PaidOnAccept(
        bytes32 indexed questionId,
        bytes32 indexed answerId,
        address to,
        uint256 paid,
        uint256 fee,
        uint256 stakeReturned
    );

    /// @notice Emitted when payout occurs after answer rejection
    event PaidOnReject(
        bytes32 indexed questionId,
        bytes32 indexed answerId,
        address asker,
        uint256 refundToAsker,
        uint256 fee,
        uint256 stakeAwarded
    );

    /// @notice Emitted when payout occurs due to timeout
    event PaidOnTimeout(
        bytes32 indexed questionId,
        bytes32 indexed answerId,
        address asker,
        uint256 askerRefund,
        uint256 askerFee,
        address responder,
        uint256 responderRefund,
        uint256 responderFee
    );

    /// @notice Emitted when the Pool is linked to the Answers contract
    event ContractLinked(address answersContract);

    // ============================================================
    //                      MODIFIERS
    // ============================================================

    /// @dev Restricts access to contract owner
    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    /// @dev Restricts access to the linked Answers contract only
    modifier onlyAnswers() {
        require(msg.sender == answersContract, "only Answers");
        _;
    }

    // ============================================================
    //                      CONSTRUCTOR
    // ============================================================

    /**
     * @notice Initializes the Pool contract
     * @dev The deployer becomes the owner and can later link the Answers contract.
     */
    constructor() {
        owner = msg.sender;
    }

    // ============================================================
    //                      ADMIN
    // ============================================================

    /**
     * @notice Links the Pool to a deployed Answers contract.
     * @dev Only callable by the owner once per deployment.
     * @param _answers Address of the deployed Answers contract.
     */
    function linkAnswersContract(address _answers) external onlyOwner {
        require(_answers != address(0), "answers=0");
        answersContract = _answers;
        emit ContractLinked(_answers);
    }

    // ============================================================
    //                  FUND DEPOSIT FUNCTIONS
    // ============================================================

    /**
     * @notice Called by Answers contract when asker creates a question.
     * @dev Stores ETH deposit associated with the question ID.
     * @param _questionId Unique ID of the question.
     */
    function depositQuestion(bytes32 _questionId) external payable onlyAnswers nonReentrant {
        require(msg.value > 0, "zero deposit");
        questionBalance[_questionId] += msg.value;
        emit DepositedQuestion(_questionId, msg.value);
    }

    /**
     * @notice Called by Answers contract when responder submits an answer with a stake.
     * @dev Stores responder’s ETH stake associated with answer ID.
     * @param _answerId Unique ID of the answer.
     */
    function depositStake(bytes32 _answerId) external payable onlyAnswers nonReentrant {
        require(msg.value > 0, "zero stake");
        stakeBalance[_answerId] += msg.value;
        emit DepositedStake(_answerId, msg.value);
    }

    // ============================================================
    //                  PAYOUT SCENARIOS
    // ============================================================

    /**
     * @notice ACCEPT scenario — The answer is approved by the asker.
     * @dev Transfers deposit (minus platform fee) and responder’s full stake back to the responder.
     * @param _questionId Question ID
     * @param _answerId Answer ID
     * @param _responder Address of responder (receiver)
     * @param _feeReceiver Address that receives platform fees
     * @param _feeAcceptBps Platform fee in basis points (e.g., 500 = 5%)
     * @return paid Actual payout to responder (without stake)
     * @return fee Fee sent to platform
     */
    function payoutOnAccept(
        bytes32 _questionId,
        bytes32 _answerId,
        address payable _responder,
        address payable _feeReceiver,
        uint16 _feeAcceptBps
    ) external onlyAnswers nonReentrant returns (uint256 paid, uint256 fee) {
        uint256 deposit = questionBalance[_questionId];
        require(deposit > 0, "empty deposit");
        questionBalance[_questionId] = 0;

        uint256 stake = stakeBalance[_answerId];
        stakeBalance[_answerId] = 0;

        fee  = (deposit * _feeAcceptBps) / 10000;
        paid = deposit - fee;

        if (paid > 0) {
            (bool ok1, ) = _responder.call{value: paid}("");
            require(ok1, "pay fail");
        }
        if (fee > 0) {
            (bool ok2, ) = _feeReceiver.call{value: fee}("");
            require(ok2, "fee fail");
        }
        if (stake > 0) {
            (bool ok3, ) = _responder.call{value: stake}("");
            require(ok3, "stake return fail");
        }

        emit PaidOnAccept(_questionId, _answerId, _responder, paid, fee, stake);
    }

    /**
     * @notice REJECT scenario — The answer is declined by the asker.
     * @dev Refunds asker (minus platform fee) and transfers responder’s stake to asker as compensation.
     * @param _questionId Question ID
     * @param _answerId Answer ID
     * @param _asker Address of asker (receiver)
     * @param _feeReceiver Address that receives platform fees
     * @param _feeRejectBps Platform fee in basis points (e.g., 1000 = 10%)
     * @return refundToAsker Deposit amount returned to asker
     * @return feeTaken Platform fee charged
     * @return stakeAwarded Responder’s stake sent to asker
     */
    function payoutOnReject(
        bytes32 _questionId,
        bytes32 _answerId,
        address payable _asker,
        address payable _feeReceiver,
        uint16 _feeRejectBps
    ) external onlyAnswers nonReentrant returns (uint256 refundToAsker, uint256 feeTaken, uint256 stakeAwarded) {
        uint256 deposit = questionBalance[_questionId];
        require(deposit > 0, "empty deposit");
        questionBalance[_questionId] = 0;

        uint256 stake = stakeBalance[_answerId];
        require(stake > 0, "empty stake");
        stakeBalance[_answerId] = 0;

        feeTaken      = (deposit * _feeRejectBps) / 10000;
        refundToAsker = deposit - feeTaken;
        stakeAwarded  = stake;

        if (refundToAsker > 0) {
            (bool ok1, ) = _asker.call{value: refundToAsker}("");
            require(ok1, "asker refund fail");
        }
        if (feeTaken > 0) {
            (bool ok2, ) = _feeReceiver.call{value: feeTaken}("");
            require(ok2, "fee fail");
        }
        if (stakeAwarded > 0) {
            (bool ok3, ) = _asker.call{value: stakeAwarded}("");
            require(ok3, "stake to asker fail");
        }

        emit PaidOnReject(_questionId, _answerId, _asker, refundToAsker, feeTaken, stakeAwarded);
    }

    /**
     * @notice TIMEOUT scenario — Neither side acted before the deadline.
     * @dev Refunds both parties minus a small timeout fee.
     *      If no answer was selected, only the asker is refunded.
     * @param _questionId Question ID
     * @param _answerId Answer ID (can be zero)
     * @param _asker Address of asker
     * @param _responder Address of responder (if any)
     * @param _feeReceiver Address of fee receiver
     * @param _feeTimeoutBps Timeout fee in basis points (e.g., 500 = 5%)
     * @return askerRefund Amount refunded to asker
     * @return askerFee Fee taken from asker
     * @return responderRefund Amount refunded to responder
     * @return responderFee Fee taken from responder
     */
    function payoutOnTimeout(
        bytes32 _questionId,
        bytes32 _answerId,
        address payable _asker,
        address payable _responder,
        address payable _feeReceiver,
        uint16 _feeTimeoutBps
    )
        external
        onlyAnswers
        nonReentrant
        returns (
            uint256 askerRefund,
            uint256 askerFee,
            uint256 responderRefund,
            uint256 responderFee
        )
    {
        uint256 deposit = questionBalance[_questionId];
        require(deposit > 0, "empty deposit");
        questionBalance[_questionId] = 0;

        // deposit → asker minus timeout fee
        askerFee    = (deposit * _feeTimeoutBps) / 10000;
        askerRefund = deposit - askerFee;

        if (askerRefund > 0) {
            (bool ok1, ) = _asker.call{value: askerRefund}("");
            require(ok1, "asker refund fail");
        }
        if (askerFee > 0) {
            (bool ok2, ) = _feeReceiver.call{value: askerFee}("");
            require(ok2, "fee fail");
        }

        // if a responder exists, refund stake minus same fee
        if (_answerId != bytes32(0)) {
            uint256 stake = stakeBalance[_answerId];
            if (stake > 0) {
                stakeBalance[_answerId] = 0;
                responderFee    = (stake * _feeTimeoutBps) / 10000;
                responderRefund = stake - responderFee;

                if (responderRefund > 0) {
                    (bool ok3, ) = _responder.call{value: responderRefund}("");
                    require(ok3, "responder refund fail");
                }
                if (responderFee > 0) {
                    (bool ok4, ) = _feeReceiver.call{value: responderFee}("");
                    require(ok4, "fee fail");
                }
            }
        }

        emit PaidOnTimeout(_questionId, _answerId, _asker, askerRefund, askerFee, _responder, responderRefund, responderFee);
    }

    /**
     * @notice Allows the contract to receive plain ETH transfers.
     * @dev Used for safety or direct funding (e.g., refunds, tests).
     */
    receive() external payable {}
}
