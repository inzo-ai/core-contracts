// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface IPolicyLogicContract {
    enum PolicyLogicPolicyStatus { PENDING_PAYMENT, ACTIVE, LAPSED, CLAIM_ACTIVE, PAID_OUT, EXPIRED, CANCELLED }
    function updatePolicyStatusAfterClaim(uint256 policyNFTId, PolicyLogicPolicyStatus newStatus) external;
    function getPolicyData(uint256 policyNFTId) external view returns (
        address originalOwner,
        uint256 policyNFTId_return, 
        string memory deviceIdentifier,
        uint256 coverageAmount,
        uint256 premiumAmount,
        uint256 premiumIntervalSeconds,
        uint256 lastPremiumPaidTimestamp,
        uint256 policyEndDate,
        uint8 status, 
        string memory termsHash,
        bytes32 evidenceBundleHash
    );
}

interface ITreasuryContract {
    function processPayout(address recipient, uint256 amount) external;
}

contract ClaimProcessorContract {
    address public admin;
    IPolicyLogicContract public policyLogicContract;
    ITreasuryContract public treasuryContract;
    address public aiOracleAddress; 
    address public humanReviewerOracleAddress; 

    uint256 public nextClaimProcessorId;

    struct ClaimDetails {
        uint256 originalPolicyNFTId;
        address claimant;
        bytes32 incidentDescriptionHash; 
        bytes32 evidenceBundleHash;    
        uint256 requestedAmount;
        uint256 assessedPayoutAmount;
        string assessmentReportHash; 
        ClaimProcessingStatus status;
        uint256 claimFiledTimestamp;   
        uint256 assessmentTimestamp;
        uint8 aiConfidenceScore; 
        bool fraudRiskDetectedByAI;
    }

    enum ClaimProcessingStatus {
        PENDING_ASSESSMENT,       
        AI_APPROVED_LOW_RISK,       
        AI_APPROVED_NEEDS_REVIEW,   
        AI_REJECTED_NEEDS_REVIEW,   
        AI_CLARIFICATION_REQUESTED, 
        AI_NEEDS_HUMAN_REVIEW,      
        HUMAN_APPROVED,
        HUMAN_REJECTED,
        PAYOUT_AUTHORIZED,          
        CLOSED_PAID,
        CLOSED_REJECTED_FINAL
    }

    mapping(uint256 => ClaimDetails) public claims; 

    event ClaimReceivedForProcessing(uint256 indexed claimProcessorId, uint256 indexed originalPolicyNFTId, address indexed claimant);
    event ClaimAssessmentSubmitted(uint256 indexed claimProcessorId, address indexed assessor, ClaimProcessingStatus suggestedStatus, uint8 confidence, bool fraudRisk);
    event ClaimProcessingStatusChanged(uint256 indexed claimProcessorId, ClaimProcessingStatus newStatus, uint256 payoutAmount);
    event PayoutAuthorizedForClaim(uint256 indexed claimProcessorId, address indexed recipient, uint256 amount);

    modifier onlyAdmin() {
        require(msg.sender == admin, "CPC: Not admin");
        _;
    }
    modifier onlyAIOracle() {
        require(msg.sender == aiOracleAddress, "CPC: Not AI oracle");
        _;
    }
    modifier onlyHumanReviewerOracle() {
        require(msg.sender == humanReviewerOracleAddress, "CPC: Not Human Reviewer oracle");
        _;
    }

    constructor(address _policyLogicAddress, address _treasuryAddress, address _initialAIOracle, address _initialHumanReviewer) {
        admin = msg.sender;
        require(_policyLogicAddress != address(0), "CPC: Invalid PolicyLogic address");
        require(_treasuryAddress != address(0), "CPC: Invalid Treasury address");
        require(_initialAIOracle != address(0), "CPC: Invalid AI Oracle address");
        require(_initialHumanReviewer != address(0), "CPC: Invalid Human Reviewer address");

        policyLogicContract = IPolicyLogicContract(_policyLogicAddress);
        treasuryContract = ITreasuryContract(_treasuryAddress);
        aiOracleAddress = _initialAIOracle;
        humanReviewerOracleAddress = _initialHumanReviewer;
    }

    function registerClaimForProcessing(
        uint256 originalPolicyNFTId,
        address claimant,
        string calldata incidentDescription,
        bytes32 evidenceHashFromLogicContract, 
        uint256 requestedAmountFromLogicContract,
        uint256 claimFiledTimestampFromLogicContract
    ) external onlyAIOracle returns (uint256 claimProcessorId) { 
        
        (,,,,uint256 coverageAmount,,,,,,) = policyLogicContract.getPolicyData(originalPolicyNFTId);
        require(requestedAmountFromLogicContract <= coverageAmount, "CPC: Requested amount exceeds coverage");

        claimProcessorId = nextClaimProcessorId++;
        claims[claimProcessorId] = ClaimDetails({
            originalPolicyNFTId: originalPolicyNFTId,
            claimant: claimant,
            incidentDescriptionHash: keccak256(abi.encodePacked(incidentDescription)),
            evidenceBundleHash: evidenceHashFromLogicContract,
            requestedAmount: requestedAmountFromLogicContract,
            assessedPayoutAmount: 0,
            assessmentReportHash: "",
            status: ClaimProcessingStatus.PENDING_ASSESSMENT,
            claimFiledTimestamp: claimFiledTimestampFromLogicContract,
            assessmentTimestamp: 0,
            aiConfidenceScore: 0,
            fraudRiskDetectedByAI: false
        });
        emit ClaimReceivedForProcessing(claimProcessorId, originalPolicyNFTId, claimant);
        return claimProcessorId;
    }

    function submitAIAssessment(
        uint256 claimProcessorId,
        uint256 aiRecommendedPayout,
        uint8 confidenceScore, 
        bool fraudRiskDetected,
        string calldata aiAssessmentReportHash
    ) external onlyAIOracle {
        ClaimDetails storage claim = claims[claimProcessorId];
        require(claim.status == ClaimProcessingStatus.PENDING_ASSESSMENT || claim.status == ClaimProcessingStatus.AI_CLARIFICATION_REQUESTED, "CPC: Claim not awaiting AI assessment");
        
        (,,,,uint256 coverageAmount,,,,,,) = policyLogicContract.getPolicyData(claim.originalPolicyNFTId);
        require(aiRecommendedPayout <= coverageAmount, "CPC: AI Payout exceeds coverage");

        claim.assessedPayoutAmount = aiRecommendedPayout;
        claim.assessmentReportHash = aiAssessmentReportHash;
        claim.assessmentTimestamp = block.timestamp;
        claim.aiConfidenceScore = confidenceScore;
        claim.fraudRiskDetectedByAI = fraudRiskDetected;

        _processAssessmentRules(claimProcessorId); 
    }

    function _processAssessmentRules(uint256 claimProcessorId) internal {
        ClaimDetails storage claim = claims[claimProcessorId];
        ClaimProcessingStatus previousStatus = claim.status; 

        (,,,,uint256 coverageAmount,,,,,,) = policyLogicContract.getPolicyData(claim.originalPolicyNFTId);

        if (claim.fraudRiskDetectedByAI) {
            claim.status = ClaimProcessingStatus.AI_REJECTED_NEEDS_REVIEW;
        } else if (claim.aiConfidenceScore >= 90 && claim.assessedPayoutAmount > 0 && claim.assessedPayoutAmount <= (coverageAmount / 20)) { 
            claim.status = ClaimProcessingStatus.AI_APPROVED_LOW_RISK; 
        } else if (claim.aiConfidenceScore >= 75 && claim.assessedPayoutAmount > 0) {
            claim.status = ClaimProcessingStatus.AI_APPROVED_NEEDS_REVIEW;
        } else if (claim.aiConfidenceScore < 50 || (claim.assessedPayoutAmount == 0 && !claim.fraudRiskDetectedByAI)) {
             claim.status = ClaimProcessingStatus.AI_REJECTED_NEEDS_REVIEW; 
        } else {
            claim.status = ClaimProcessingStatus.AI_NEEDS_HUMAN_REVIEW; 
        }

        if(claim.status != previousStatus){
            emit ClaimProcessingStatusChanged(claimProcessorId, claim.status, claim.assessedPayoutAmount);
        }
    }
    
    function requestAIClarification(uint256 claimProcessorId, string calldata reasonHash) external onlyAIOracle {
        ClaimDetails storage claim = claims[claimProcessorId];
        require(claim.status == ClaimProcessingStatus.PENDING_ASSESSMENT, "CPC: Not pending initial assessment");
        claim.status = ClaimProcessingStatus.AI_CLARIFICATION_REQUESTED;
        claim.assessmentReportHash = reasonHash; 
        emit ClaimProcessingStatusChanged(claimProcessorId, claim.status, 0);
    }

    function submitHumanReview(
        uint256 claimProcessorId,
        bool isApprovedByHuman,
        uint256 finalPayoutAmount,
        string calldata humanReviewReportHash
    ) external onlyHumanReviewerOracle {
        ClaimDetails storage claim = claims[claimProcessorId];
        require(
            claim.status == ClaimProcessingStatus.AI_APPROVED_NEEDS_REVIEW ||
            claim.status == ClaimProcessingStatus.AI_REJECTED_NEEDS_REVIEW ||
            claim.status == ClaimProcessingStatus.AI_NEEDS_HUMAN_REVIEW,
            "CPC: Claim not awaiting human review"
        );
        
        (,,,,uint256 coverageAmount,,,,,,) = policyLogicContract.getPolicyData(claim.originalPolicyNFTId);
        require(finalPayoutAmount <= coverageAmount, "CPC: Human Payout exceeds coverage");

        claim.assessmentReportHash = humanReviewReportHash;
        claim.assessmentTimestamp = block.timestamp; 

        if (isApprovedByHuman) {
            claim.status = ClaimProcessingStatus.HUMAN_APPROVED;
            claim.assessedPayoutAmount = finalPayoutAmount;
        } else {
            claim.status = ClaimProcessingStatus.HUMAN_REJECTED;
            claim.assessedPayoutAmount = 0;
        }
        emit ClaimProcessingStatusChanged(claimProcessorId, claim.status, claim.assessedPayoutAmount);
    }

    function authorizeAndProcessPayout(uint256 claimProcessorId) external {
        ClaimDetails storage claim = claims[claimProcessorId];
        require(msg.sender == admin || msg.sender == humanReviewerOracleAddress, "CPC: Not authorized for payout trigger");
        require(
            claim.status == ClaimProcessingStatus.AI_APPROVED_LOW_RISK || 
            claim.status == ClaimProcessingStatus.HUMAN_APPROVED,
            "CPC: Claim not in approved state for payout"
        );
        
        IPolicyLogicContract.PolicyLogicPolicyStatus policyLogicStatusUpdate;

        claim.status = ClaimProcessingStatus.PAYOUT_AUTHORIZED;
        emit PayoutAuthorizedForClaim(claimProcessorId, claim.claimant, claim.assessedPayoutAmount);

        treasuryContract.processPayout(claim.claimant, claim.assessedPayoutAmount);
        
        claim.status = ClaimProcessingStatus.CLOSED_PAID;
        
        policyLogicStatusUpdate = IPolicyLogicContract.PolicyLogicPolicyStatus.PAID_OUT;
        policyLogicContract.updatePolicyStatusAfterClaim(claim.originalPolicyNFTId, policyLogicStatusUpdate); 
        emit ClaimProcessingStatusChanged(claimProcessorId, ClaimProcessingStatus.CLOSED_PAID, claim.assessedPayoutAmount);
    }
    
    function finalizeRejectedClaim(uint256 claimProcessorId) external {
        ClaimDetails storage claim = claims[claimProcessorId];
        require(msg.sender == admin || msg.sender == humanReviewerOracleAddress, "CPC: Not authorized");
        require(
            claim.status == ClaimProcessingStatus.HUMAN_REJECTED,
            "CPC: Claim not in rejected state for finalization"
        );
        
        IPolicyLogicContract.PolicyLogicPolicyStatus policyLogicStatusUpdate;
        
        claim.status = ClaimProcessingStatus.CLOSED_REJECTED_FINAL;
        
        policyLogicStatusUpdate = IPolicyLogicContract.PolicyLogicPolicyStatus.ACTIVE;
        policyLogicContract.updatePolicyStatusAfterClaim(claim.originalPolicyNFTId, policyLogicStatusUpdate);
        emit ClaimProcessingStatusChanged(claimProcessorId, ClaimProcessingStatus.CLOSED_REJECTED_FINAL, 0);
    }

    function updateAIOracle(address _newOracle) external onlyAdmin {
        aiOracleAddress = _newOracle;
    }
    function updateHumanReviewerOracle(address _newOracle) external onlyAdmin {
        humanReviewerOracleAddress = _newOracle;
    }
    function updatePolicyLogicContract(address _newAddress) external onlyAdmin {
        policyLogicContract = IPolicyLogicContract(_newAddress);
    }
    function updateTreasuryContract(address _newAddress) external onlyAdmin {
        treasuryContract = ITreasuryContract(_newAddress);
    }
    
    function getClaimDetails(uint256 claimProcessorId) external view returns (ClaimDetails memory) {
        return claims[claimProcessorId];
    }
}