# Class DAO: presentation voting on Sepolia

Let's find people's choice for class presentations with some on-chain voting!

Two files:

- `ClassDAO.sol`: the smart contract. It is the CDAO token and also handles registration, sessions, check-in, votes and written questions.
- `index.html`: the whole website. Tabs: **Check in**, **Vote**, **Live**, **My progress**, and **Admin** (shown only to the wallet that deployed the contract).


---

## One-time setup for TA (about 20 minutes)

### 1. Get your TA wallet ready
1. Install MetaMask and create (or pick) the wallet you'll use as TA. This wallet becomes the admin.
2. Switch MetaMask to **Sepolia** (enable "Show test networks" in MetaMask settings).
3. Get a little Sepolia ETH from a faucet for your own transactions (deploy, start/stop/end sessions). About 0.05 ETH is plenty.

### 2. Deploy the contract (Remix, in the browser)
1. Open https://remix.ethereum.org, create a file `ClassDAO.sol`, and paste in the contract.
2. **Solidity compiler** tab: pick compiler `0.8.24` or newer. Open *Advanced configurations* and **turn on Optimization (200 runs)**. Without the optimizer the contract is too large to deploy. Click *Compile*.
3. **Deploy & run** tab: set *Environment* to **Injected Provider – MetaMask** and check that it shows Sepolia (11155111).
4. Click *Deploy* (no parameters), confirm in MetaMask, and copy the deployed contract address.

### 3. Point the site at your contract
Open `index.html` and replace the address near the top. The session dates there are only labels shown on the site; you start and end sessions yourself.

```js
const CONFIG = {
  contract: "0xYOUR_CONTRACT_ADDRESS",
  ...
  sessionDates: ["Tue Nov 17", "Thu Nov 19", "Tue Nov 24", "Tue Dec 1", "Thu Dec 3"],
```

### 4. Host it on GitHub Pages
1. Create a public GitHub repo (e.g. `class-dao`) and upload `index.html`.
2. Repo **Settings → Pages**: Source = *Deploy from a branch*, Branch = `main` / root. Save.
3. After about a minute the site is live at `https://<your-username>.github.io/class-dao/`. Post that link on Ed.

## One-time setup for students (about 5 minutes)

### 1. Students register themselves (before session 1)
1. Each student installs MetaMask, gets a little Sepolia ETH from a faucet, opens the site and clicks **Connect wallet**.
2. On the Check in tab they enter their **team number** and **NetID** (lowercase, e.g. `xy1234`) and click **Register**. Both are stored on-chain and used for grading. Each NetID can only be registered once.
3. Mistakes (wrong team, typo in NetID, lost wallet): call `setStudent(address, team, netId)` from the TA wallet in Remix or Etherscan. Giving a NetID to a new wallet removes it from the old one.

---

## Each session

| When | You (Admin tab) | Students |
|---|---|---|
| Start of class | Select the session, list the teams presenting (e.g. `3, 7, 12, 18, 21`), keep the generated code and click **Start session**. Token collection opens and the code appears full-screen for the projector. | Check in tab: enter the code. The contract gives them 10 tokens right away. |
| ~10 min in | **Stop token collection**, so the code stops working. You can reopen it, with a new code if you like. | — |
| Throughout | Project the **Live** tab if you like. It updates every few seconds and needs a connected wallet. | Vote tab: spread tokens across the teams (not their own) and submit at least 2 written questions. |
| End of class | **End session** (click twice). Voting and questions close and every unspent token expires. | — |

Late arrivals: type their NetID (or address) into *Check in manually* while the session is live; they get their 10 tokens immediately.

Only one session can be live at a time, each session can be started once, and you can run them in any order.

## Rules enforced by the contract
- 10 tokens per student per session, given by the contract when they check in (once per address per session).
- Votes for a team = √(tokens given to it), with at most 10 tokens per team. Voting for your own team is blocked.
- Students can't send tokens to each other. Tokens can only be spent as votes.
- Valid ballot = checked in + tokens on every presenting team except your own + at least 2 written questions.
- Unspent tokens expire the moment you end the session.

## Grades and feedback (Admin → Exports)
- **Participation grades (CSV)**: per student (NetID, address, team), sessions attended, valid ballots, and a *full_credit* column (at least 4 valid ballots).
- **Questions by team, anonymous (CSV)**: every written question, grouped by team, with no asker. Send each team its rows.
- **All questions with askers (CSV)**: with each asker's NetID, for your own records.

## Things to know
- **Privacy:** wallet addresses, team numbers and **NetIDs** go on a public blockchain, so anyone can link a wallet to a NetID. Written questions are on-chain too, with the asker's address.
- **Check-in code:** once a student checks in, the code is visible on the public chain. Stop token collection about 10 minutes in. To rotate the code, enter a new one and click *Stop* / *Reopen token collection*.
- The contract is set up for 5 sessions and team numbers 1–50.
