# 🧩 Answers & Pool — Decentralized Paid Q&A System

> **Author:** [Tenyokj](https://github.com/Tenyokj)  
> **Solidity Version:** 0.8.20  

---

## 📖 Overview

**Answers.sol** and **Pool.sol** form a decentralized Q&A marketplace built on Ethereum (or any EVM chain).  
Users can **post questions with ETH bounties**, while responders **submit answers with a security stake**.  
The system includes a **rating mechanism** that rewards accurate and honest participants  
and penalizes spam, fraud, or inactivity.

> In short: A trust-based Q&A system, fully on-chain.

---

## ⚙️ Architecture

| Contract | Responsibility |
|-----------|----------------|
| **Answers.sol** | Main logic — manages questions, answers, payouts, and ratings |
| **Pool.sol** | Safe ETH vault — stores deposits and stakes, executes payouts |
| **OpenZeppelin** | Provides `Ownable` and `ReentrancyGuard` for security |

### 🧱 Flow Diagram

[ Vanya (Asker) ] --deposit--> [ Pool ]
|
addQuestion()
↓
[ Dima (Responder) ] --stake--> [ Pool ]
|
submitAnswer()
↓
selectAnswer()
↓
┌──────────────────────────────────────────────────────┐
│ ACCEPT → payout to responder + return stake │
│ REJECT → refund to asker + responder loses stake │
│ TIMEOUT → both refunded minus small fee │
└──────────────────────────────────────────────────────┘


---

## 🪙 Economic Rules

| Scenario | Asker (Vanya) | Responder (Dima) | Platform |
|-----------|----------------|-----------------|-----------|
| ✅ **Accepted** | Pays full bounty | Receives bounty + stake back | 5% fee |
| ❌ **Rejected** | Gets refund (minus 10%) + responder’s stake | Loses stake | 10% fee |
| ⏰ **Timeout** | Gets refund (minus 5%) | Gets refund (minus 5%) | 5% fee each |

All values and percentages can be configured by the contract owner.

---

## 🧠 Rating System

Each responder’s behavior affects their reputation:

| Event | Rating Change |
|--------|----------------|
| Answer accepted | `+10` |
| Answer rejected | `–5` |
| Timeout (no resolution) | `–1` |

### 💡 Dynamic Stake
The required stake automatically adjusts based on rating:

| Rating | Stake Multiplier |
|---------|------------------|
| ≥ 50 | 0.5× (half) |
| ≥ 20 | 0.75× |
| ≤ –20 | 2× (double) |
| else | 1× (base) |

---

## 🧩 Contract Setup

### 1️⃣ Deploy `Pool.sol`

```solidity
Pool pool = new Pool();

### 2️⃣ Deploy Answers.sol

Pass the pool address and a feeReceiver address:

Answers answers = new Answers(payable(address(pool)), feeReceiver);

### 3️⃣ Link the contracts

pool.linkAnswersContract(address(answers));

## 🧪 Testing

Automated test suite (using Hardhat) will be added soon.
The tests will cover:

deposit and stake logic

acceptance, rejection, and timeout payouts

rating progression

dynamic stake calculation

fee distribution validation

Status: Tests planned but not yet implemented. ✅

## 🔐 Security Features

Uses OpenZeppelin ReentrancyGuard to prevent reentrancy attacks.

All fund transfers go through the Pool contract only.

Strict access control (onlyAnswers, onlyOwner).

Immutable relationships between contracts once linked.

## 🧩 Future Improvements

✅ Rating system (done)

🚧 Add unit tests

🚧 Support for ERC20 tokens

🚧 DAO-based dispute resolution

🚧 On-chain voting for answer validation

## 📄 License

Copyright © 2025
Created by Tenyokj
