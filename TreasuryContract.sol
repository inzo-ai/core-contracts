// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

contract TreasuryContract {
    address public admin;
    address public policyLogicContractAddress; 
    address public claimProcessorContractAddress; 

    event FundsDeposited(address indexed from, uint256 indexed policyId, uint256 amount);
    event PayoutProcessed(address indexed recipient, uint256 amount, uint256 indexed claimId);
    event AdminWithdrawal(address indexed recipient, uint256 amount);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Treasury: Not admin");
        _;
    }

    modifier onlyPolicyLogicContract() {
        require(msg.sender == policyLogicContractAddress, "Treasury: Not PolicyLogicContract");
        _;
    }

    modifier onlyClaimProcessorContract() {
        require(msg.sender == claimProcessorContractAddress, "Treasury: Not ClaimProcessorContract");
        _;
    }

    constructor(address _initialPolicyLogic, address _initialClaimProcessor) {
        admin = msg.sender;
        require(_initialPolicyLogic != address(0), "Treasury: Invalid PolicyLogic address");
        require(_initialClaimProcessor != address(0), "Treasury: Invalid ClaimProcessor address");
        policyLogicContractAddress = _initialPolicyLogic;
        claimProcessorContractAddress = _initialClaimProcessor;
    }

    function depositPremium(address payer, uint256 policyId, uint256 amount) external payable onlyPolicyLogicContract {
        require(msg.value == amount, "Treasury: Sent value mismatch");
        emit FundsDeposited(payer, policyId, msg.value);
    }

    function processPayout(address recipient, uint256 amount, uint256 claimId) external onlyClaimProcessorContract {
        require(recipient != address(0), "Treasury: Payout to zero address");
        require(address(this).balance >= amount, "Treasury: Insufficient funds for payout");
        
        (bool success, ) = payable(recipient).call{value: amount}("");
        require(success, "Treasury: Payout transfer failed");

        emit PayoutProcessed(recipient, amount, claimId);
    }

    function adminWithdrawExcess(address payable recipient, uint256 amount) external onlyAdmin {
        require(recipient != address(0), "Treasury: Withdrawal to zero address");
        require(address(this).balance >= amount, "Treasury: Insufficient funds for withdrawal");
        
        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Treasury: Admin withdrawal failed");

        emit AdminWithdrawal(recipient, amount);
    }
    
    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function setPolicyLogicContract(address _newAddress) external onlyAdmin {
        require(_newAddress != address(0), "Treasury: Invalid PolicyLogic address");
        policyLogicContractAddress = _newAddress;
    }

    function setClaimProcessorContract(address _newAddress) external onlyAdmin {
        require(_newAddress != address(0), "Treasury: Invalid ClaimProcessor address");
        claimProcessorContractAddress = _newAddress;
    }

    receive() external payable {}
}