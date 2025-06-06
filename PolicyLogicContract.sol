// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface IPolicyNFT {
    function mintPolicyNFT(address recipient, string memory uri) external returns (uint256);
    function burnPolicyNFT(uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
    function updateTokenURI(uint256 tokenId, string memory newUri) external;
}

interface IKYCRegistry {
    function isUserKYCVerified(address user) external view returns (bool);
}

interface ITreasury {
    function depositPremium(address payer, uint256 policyId, uint256 amount) external payable;
}

contract PolicyLogicContract {
    address public admin;
    IPolicyNFT public policyNFTContract;
    IKYCRegistry public kycRegistryContract; 
    ITreasury public treasuryContract;
    address public claimProcessorContractAddress; 

    uint256 public nextInternalPolicyId; 

    struct PolicyData {
        address originalOwner;
        uint256 policyNFTId; 
        string deviceIdentifier;
        uint256 coverageAmount;
        uint256 premiumAmount;
        uint256 premiumIntervalSeconds;
        uint256 lastPremiumPaidTimestamp;
        uint256 policyEndDate;
        PolicyStatus status;
        string termsHash; 
        bytes32 evidenceBundleHash; 
    }

    enum PolicyStatus { PENDING_PAYMENT, ACTIVE, LAPSED, CLAIM_ACTIVE, PAID_OUT, EXPIRED, CANCELLED }

    mapping(uint256 => PolicyData) public policyDetails; 

    event PolicyCreated(uint256 indexed policyNFTId, address indexed policyHolder, uint256 coverageAmount, string termsHash);
    event PremiumRecorded(uint256 indexed policyNFTId, uint256 amount, uint256 nextDueDate);
    event PolicyLogicStatusChanged(uint256 indexed policyNFTId, PolicyStatus newStatus);
    event ClaimForwardedToProcessor(uint256 indexed policyNFTId, address indexed claimant, uint256 internalClaimId, bytes32 evidenceHashForClaim);

    modifier onlyAdmin() {
        require(msg.sender == admin, "PLC: Not admin");
        _;
    }

    modifier onlyPolicyNFTOwner(uint256 policyNFTId) {
        require(policyNFTContract.ownerOf(policyNFTId) == msg.sender, "PLC: Not policy NFT owner");
        _;
    }
    
    modifier onlyClaimProcessor() {
        require(msg.sender == claimProcessorContractAddress, "PLC: Caller is not the Claim Processor");
        _;
    }

    constructor(address _policyNFTAddress, address _kycRegistryAddress, address _treasuryAddress) {
        admin = msg.sender;
        require(_policyNFTAddress != address(0), "PLC: Invalid PolicyNFT address");
        require(_kycRegistryAddress != address(0), "PLC: Invalid KYCRegistry address");
        require(_treasuryAddress != address(0), "PLC: Invalid Treasury address");
        
        policyNFTContract = IPolicyNFT(_policyNFTAddress);
        kycRegistryContract = IKYCRegistry(_kycRegistryAddress); 
        treasuryContract = ITreasury(_treasuryAddress);
    }

    function setClaimProcessorContract(address _processorAddress) external onlyAdmin {
        require(_processorAddress != address(0), "PLC: Invalid ClaimProcessor address");
        claimProcessorContractAddress = _processorAddress;
    }

    function createPolicy(
        address policyHolder,
        string calldata deviceIdentifier,
        uint256 coverageAmount,
        uint256 premiumAmount,
        uint256 premiumIntervalSeconds,
        uint256 policyDurationSeconds,
        string calldata nftMetadataURI,
        string calldata termsHashString
    ) external payable returns (uint256 policyNFTId) {
        require(kycRegistryContract.isUserKYCVerified(policyHolder), "PLC: User not KYC verified");
        require(msg.value == premiumAmount, "PLC: Initial premium not paid correctly");
        require(premiumIntervalSeconds > 0, "PLC: Premium interval must be positive");
        require(policyDurationSeconds > 0, "PLC: Policy duration must be positive");

        policyNFTId = policyNFTContract.mintPolicyNFT(policyHolder, nftMetadataURI);
        
        policyDetails[policyNFTId] = PolicyData({
            originalOwner: policyHolder,
            policyNFTId: policyNFTId,
            deviceIdentifier: deviceIdentifier,
            coverageAmount: coverageAmount,
            premiumAmount: premiumAmount,
            premiumIntervalSeconds: premiumIntervalSeconds,
            lastPremiumPaidTimestamp: block.timestamp,
            policyEndDate: block.timestamp + policyDurationSeconds,
            status: PolicyStatus.ACTIVE,
            termsHash: termsHashString,
            evidenceBundleHash: bytes32(0) 
        });

        treasuryContract.depositPremium{value: msg.value}(policyHolder, policyNFTId, premiumAmount);

        emit PolicyCreated(policyNFTId, policyHolder, coverageAmount, termsHashString);
        emit PolicyLogicStatusChanged(policyNFTId, PolicyStatus.ACTIVE);
        return policyNFTId;
    }

    function recordPremiumPayment(uint256 policyNFTId) external payable onlyPolicyNFTOwner(policyNFTId) {
        PolicyData storage policy = policyDetails[policyNFTId];
        require(policy.status == PolicyStatus.ACTIVE || policy.status == PolicyStatus.LAPSED, "PLC: Policy not eligible for premium");
        require(block.timestamp < policy.policyEndDate, "PLC: Policy expired");
        require(msg.value == policy.premiumAmount, "PLC: Incorrect premium amount");

        policy.lastPremiumPaidTimestamp = block.timestamp;
        if (policy.status == PolicyStatus.LAPSED) {
        }
        policy.status = PolicyStatus.ACTIVE;
        
        treasuryContract.depositPremium{value: msg.value}(msg.sender, policyNFTId, msg.value);

        emit PremiumRecorded(policyNFTId, msg.value, policy.lastPremiumPaidTimestamp + policy.premiumIntervalSeconds);
        emit PolicyLogicStatusChanged(policyNFTId, PolicyStatus.ACTIVE);
    }
    
    function checkAndUpdatePolicyStatus(uint256 policyNFTId) external {
        PolicyData storage policy = policyDetails[policyNFTId];
        bool statusChanged = false;

        if (policy.status == PolicyStatus.ACTIVE && block.timestamp > policy.lastPremiumPaidTimestamp + policy.premiumIntervalSeconds) {
            policy.status = PolicyStatus.LAPSED;
            statusChanged = true;
        }
        if (block.timestamp > policy.policyEndDate && policy.status != PolicyStatus.PAID_OUT && policy.status != PolicyStatus.EXPIRED && policy.status != PolicyStatus.CANCELLED) {
            policy.status = PolicyStatus.EXPIRED;
            statusChanged = true;
        }

        if (statusChanged) {
            emit PolicyLogicStatusChanged(policyNFTId, policy.status);
        }
    }

    function initiateClaimFiling(
        uint256 policyNFTId,
        string calldata incidentDescription, 
        string[] calldata evidenceLinks,     
        uint256 requestedClaimAmount
    ) external onlyPolicyNFTOwner(policyNFTId) returns (uint256 internalClaimId) {
        PolicyData storage policy = policyDetails[policyNFTId];
        require(policy.status == PolicyStatus.ACTIVE, "PLC: Policy not active for claims");
        require(requestedClaimAmount <= policy.coverageAmount, "PLC: Requested amount exceeds coverage");
        require(claimProcessorContractAddress != address(0), "PLC: ClaimProcessor not set");

        bytes32 evidenceHash;
        if (evidenceLinks.length > 0) {
            bytes memory concatenatedLinks;
            for (uint i = 0; i < evidenceLinks.length; i++) {
                concatenatedLinks = abi.encodePacked(concatenatedLinks, evidenceLinks[i]);
            }
            evidenceHash = keccak256(concatenatedLinks);
        } else {
            evidenceHash = bytes32(0);
        }
        policy.evidenceBundleHash = evidenceHash;

        policy.status = PolicyStatus.CLAIM_ACTIVE;
        emit PolicyLogicStatusChanged(policyNFTId, PolicyStatus.CLAIM_ACTIVE);

        internalClaimId = uint256(keccak256(abi.encodePacked(policyNFTId, msg.sender, block.timestamp, incidentDescription, evidenceHash))); 

        emit ClaimForwardedToProcessor(policyNFTId, msg.sender, internalClaimId, evidenceHash); 
        
        return internalClaimId; 
    }

    function updatePolicyStatusAfterClaim(uint256 policyNFTId, PolicyStatus newStatus) external onlyClaimProcessor {
        require(policyDetails[policyNFTId].originalOwner != address(0), "PLC: Policy does not exist");
        policyDetails[policyNFTId].status = newStatus; 
        emit PolicyLogicStatusChanged(policyNFTId, newStatus);
    }
    
    function getPolicyData(uint256 policyNFTId) external view returns (PolicyData memory) {
        return policyDetails[policyNFTId];
    }

    function updatePolicyNFTContract(address _newPolicyNFTAddress) external onlyAdmin {
        require(_newPolicyNFTAddress != address(0), "PLC: Invalid PolicyNFT address");
        policyNFTContract = IPolicyNFT(_newPolicyNFTAddress);
    }
    function updateKYCRegistryContract(address _newKYCRegistryAddress) external onlyAdmin {
        require(_newKYCRegistryAddress != address(0), "PLC: Invalid KYCRegistry address");
        kycRegistryContract = IKYCRegistry(_newKYCRegistryAddress);
    }
    function updateTreasuryContract(address _newTreasuryAddress) external onlyAdmin {
        require(_newTreasuryAddress != address(0), "PLC: Invalid Treasury address");
        treasuryContract = ITreasury(_newTreasuryAddress);
    }
}