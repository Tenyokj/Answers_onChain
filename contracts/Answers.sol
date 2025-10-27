// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Pool} from "./Pool.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Answers.sol — Decentralized Paid Q&A Contract
 * @author Tenyokj
 * @notice This contract allows users to post questions with ETH deposits
 *         and lets responders submit answers with an ETH stake as a guarantee of quality.
 *         The rating system rewards accurate answers and penalizes poor or ignored ones.
 * @dev Works together with Pool.sol which handles all fund transfers.
 *      Utilizes OpenZeppelin's ReentrancyGuard and Ownable for security and admin control.
 */
contract Answers is ReentrancyGuard, Ownable {
    /// @notice Reference to the Pool contract which stores and transfers funds
    Pool public pool;

    // --- Platform parameters (basis points: 10000 = 100%) ---
    /// @notice Fee percentage taken by the platform when an answer is accepted
    uint16 public feeAcceptBps  = 500;     // 5%
    /// @notice Fee percentage taken when an answer is rejected
    uint16 public feeRejectBps  = 1000;    // 10%
    /// @notice Fee percentage taken when timeout occurs
    uint16 public feeTimeoutBps = 500;     // 5%

    /// @notice Address that receives platform fees
    address public feeReceiver;
    /// @notice Base minimum stake required for a responder
    uint256 public baseStake = 0.001 ether;
    /// @notice Time window for accepting/rejecting answers (default 10 hours)
    uint256 public mutualTimeout = 10 hours;

    /**
     * @dev Initializes the Answers contract with a linked Pool and fee receiver.
     * @param _pool Address of the deployed Pool contract
     * @param _feeReceiver Address that receives all platform fees
     */
    constructor(address payable _pool, address _feeReceiver) Ownable(msg.sender) {
        require(_pool != address(0) && _feeReceiver != address(0), "zero");
        pool = Pool(_pool);
        feeReceiver = _feeReceiver;
    }

    // =====================================================
    //                      RATING SYSTEM
    // =====================================================

    /**
     * @notice Stores responder performance metrics and rating.
     * @param accepted Number of accepted answers
     * @param rejected Number of rejected answers
     * @param total Total number of submitted answers
     * @param rating Cumulative rating (can be negative)
     */
    struct UserStats {
        uint32 accepted;
        uint32 rejected;
        uint32 total;
        int256 rating;
    }

    /// @notice Mapping of user addresses to their performance stats
    mapping(address => UserStats) public stats;

    event RatingUpdated(address indexed user, int256 newRating, uint32 accepted, uint32 rejected, uint32 total);

    // =====================================================
    //                 CORE DATA STRUCTURES
    // =====================================================

    /// @notice Represents the current state of a question
    enum QState { Open, Selected, Resolved, Refunded }

    /**
     * @notice Represents an answer submitted by a responder.
     * @param id Unique answer ID
     * @param questionId Linked question ID
     * @param text Text content of the answer
     * @param owner Author (responder) address
     * @param createdAt Timestamp when submitted
     * @param stake Amount of ETH staked by the responder
     */
    struct Answer {
        bytes32 id;
        bytes32 questionId;
        string  text;
        address owner;
        uint256 createdAt;
        uint256 stake;
    }

    /**
     * @notice Represents a question posted by an asker.
     * @param id Unique question ID
     * @param text The question text
     * @param price ETH deposit amount placed by asker
     * @param owner Asker (question author)
     * @param state Lifecycle state of the question
     * @param selectedAnswerId Chosen answer ID (if any)
     * @param deadline Expiration timestamp for mutual confirmation
     */
    struct Question {
        bytes32 id;
        string  text;
        uint256 price;
        address owner;
        QState  state;
        bytes32 selectedAnswerId;
        uint256 deadline;
    }

    Question[] public questions;
    mapping(bytes32 => Question) public questionById;
    mapping(bytes32 => Answer)   public answerById;
    mapping(bytes32 => bytes32[]) public answersOfQuestion;

    // =====================================================
    //                      EVENTS
    // =====================================================

    event QuestionAdded(bytes32 indexed id, string text, uint256 price, address indexed owner);
    event AnswerSubmitted(bytes32 indexed qid, bytes32 indexed aid, address indexed responder, uint256 stake);
    event AnswerSelected(bytes32 indexed qid, bytes32 indexed aid, uint256 deadline);
    event AnswerAccepted(bytes32 indexed qid, bytes32 indexed aid, address to);
    event AnswerRejected(bytes32 indexed qid, bytes32 indexed aid, address to);
    event TimedOut(bytes32 indexed qid);

    // =====================================================
    //                      PUBLIC VIEWS
    // =====================================================

    /**
     * @notice Returns responder statistics.
     * @param user Address of the responder
     * @return UserStats struct with full stats
     */
    function getUserStats(address user) external view returns (UserStats memory) {
        return stats[user];
    }

    /**
     * @notice Calculates the required stake for a responder depending on rating.
     * @param responder Address of responder
     * @return Stake amount in wei
     */
    function requiredStake(address responder) public view returns (uint256) {
        int256 r = stats[responder].rating;
        if (r >= 50) return baseStake / 2;
        if (r >= 20) return (baseStake * 3) / 4;
        if (r <= -20) return baseStake * 2;
        return baseStake;
    }

    // =====================================================
    //                  QUESTION LIFECYCLE
    // =====================================================

    /// @notice Creates a question with attached ETH deposit sent to Pool.
    /// @param _text Text of the question.
    function addQuestion(string memory _text) external payable nonReentrant {
        require(bytes(_text).length != 0, "empty");
        require(msg.value >= 0.0001 ether, "min 0.0001");
        bytes32 qid = keccak256(abi.encodePacked(msg.sender, _text, block.timestamp, address(this)));
        (bool ok, ) = payable(address(pool)).call{ value: msg.value }(
            abi.encodeWithSignature("depositQuestion(bytes32)", qid)
        );
        require(ok, "deposit fail");
        Question memory q = Question(qid, _text, msg.value, msg.sender, QState.Open, bytes32(0), 0);
        questions.push(q);
        questionById[qid] = q;
        emit QuestionAdded(qid, _text, msg.value, msg.sender);
    }

    /// @notice Submits an answer with ETH stake based on responder rating.
    /// @param _qid Target question ID.
    /// @param _text The full answer text.
    function submitAnswer(bytes32 _qid, string memory _text) external payable nonReentrant {
        Question storage q = questionById[_qid];
        require(q.owner != address(0) && (q.state == QState.Open || q.state == QState.Selected), "bad q");
        require(bytes(_text).length != 0, "empty");
        uint256 needed = requiredStake(msg.sender);
        require(msg.value >= needed, "stake too low");
        bytes32 aid = keccak256(abi.encodePacked(msg.sender, _qid, block.timestamp));
        (bool ok, ) = payable(address(pool)).call{ value: msg.value }(
            abi.encodeWithSignature("depositStake(bytes32)", aid)
        );
        require(ok, "stake fail");
        Answer memory a = Answer(aid, _qid, _text, msg.sender, block.timestamp, msg.value);
        answerById[aid] = a;
        answersOfQuestion[_qid].push(aid);
        emit AnswerSubmitted(_qid, aid, msg.sender, msg.value);
    }

    /// @notice Asker selects a preferred answer and sets a confirmation deadline.
    function selectAnswer(bytes32 _qid, bytes32 _aid) external nonReentrant {
        Question storage q = questionById[_qid];
        require(q.owner == msg.sender, "not owner");
        Answer storage a = answerById[_aid];
        require(a.questionId == _qid, "bad aid");
        q.selectedAnswerId = _aid;
        q.state = QState.Selected;
        q.deadline = block.timestamp + mutualTimeout;
        emit AnswerSelected(_qid, _aid, q.deadline);
    }

    /// @notice Accepts the selected answer, paying responder and updating rating.
    function acceptSelectedAnswer(bytes32 _qid) external nonReentrant {
        Question storage q = questionById[_qid];
        require(q.owner == msg.sender && q.state == QState.Selected && block.timestamp <= q.deadline, "bad state");
        Answer storage a = answerById[q.selectedAnswerId];
        pool.payoutOnAccept(q.id, a.id, payable(a.owner), payable(feeReceiver), feeAcceptBps);
        q.state = QState.Resolved;
        _updateRating(a.owner, true);
        emit AnswerAccepted(q.id, a.id, a.owner);
    }

    /// @notice Rejects the selected answer, refunding asker and awarding responder's stake.
    function rejectSelectedAnswer(bytes32 _qid) external nonReentrant {
        Question storage q = questionById[_qid];
        require(q.owner == msg.sender && q.state == QState.Selected && block.timestamp <= q.deadline, "bad state");
        Answer storage a = answerById[q.selectedAnswerId];
        pool.payoutOnReject(q.id, a.id, payable(q.owner), payable(feeReceiver), feeRejectBps);
        q.state = QState.Refunded;
        _updateRating(a.owner, false);
        emit AnswerRejected(q.id, a.id, q.owner);
    }

    /// @notice Cancels question after deadline, refunding both parties with small fees.
    function cancelAfterDeadline(bytes32 _qid) external nonReentrant {
        Question storage q = questionById[_qid];
        require((q.state == QState.Selected || q.state == QState.Open) && q.deadline != 0 && block.timestamp > q.deadline, "not due");
        address responder = address(0);
        if (q.selectedAnswerId != bytes32(0)) responder = answerById[q.selectedAnswerId].owner;
        pool.payoutOnTimeout(q.id, q.selectedAnswerId, payable(q.owner), payable(responder), payable(feeReceiver), feeTimeoutBps);
        q.state = QState.Refunded;
        if (responder != address(0)) _updateRating(responder, false, true);
        emit TimedOut(q.id);
    }

    // =====================================================
    //                  INTERNAL: RATING LOGIC
    // =====================================================

    /// @dev Internal helper to update rating after accepted/rejected/timeout results.
    function _updateRating(address user, bool success) internal {
        _updateRating(user, success, false);
    }

    /// @dev Core rating adjustment logic.
    /// @param user Responder's address
    /// @param success True if answer accepted
    /// @param timeoutOnly True if timeout occurred
    function _updateRating(address user, bool success, bool timeoutOnly) internal {
        UserStats storage s = stats[user];
        if (timeoutOnly) {
            s.total++;
            s.rating -= 1;
        } else if (success) {
            s.accepted++;
            s.total++;
            s.rating += 10;
        } else {
            s.rejected++;
            s.total++;
            s.rating -= 5;
        }
        emit RatingUpdated(user, s.rating, s.accepted, s.rejected, s.total);
    }
}
