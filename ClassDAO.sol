// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ClassDAO
/// @notice Peer voting for course presentations on Sepolia.
///         - 5 sessions. The owner (TA) starts each session in class and ends it afterwards.
///         - While token collection is open, a registered student checks in with the code shown
///           in class and the contract gives them 10 CDAO tokens: once per address per session.
///         - Students spend tokens on presenting teams (quadratic: votes = sqrt(tokens)) and
///           submit written questions. Unspent tokens expire when the TA ends the session.
///         - Students register themselves with their team number and NetID (paying their own gas).
///         Only wallet addresses, team numbers and NetIDs are stored on-chain.
contract ClassDAO {
    // ------------------------------------------------------------------ ERC-20 surface
    string public constant name = "Class DAO Token";
    string public constant symbol = "CDAO";
    uint8 public constant decimals = 0;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ------------------------------------------------------------------ config
    address public owner;
    uint256 public constant TOKENS_PER_SESSION = 10;
    uint8 public constant NUM_SESSIONS = 5;
    uint8 public constant MAX_TEAM = 50;
    uint256 public constant MIN_QUESTIONS = 2;

    uint8 public currentSession; // 0 = no session live

    // ------------------------------------------------------------------ state
    struct Session {
        bool started;
        bool ended;
        bool checkInOpen;
        uint8[] teams;
        address[] attendees;
    }

    struct Question {
        address asker;
        uint8 team;
        string text;
    }

    mapping(uint8 => Session) internal sessions;
    mapping(uint8 => bytes32) internal codeHash;

    mapping(address => uint8) public teamOf; // 0 = not registered
    mapping(address => string) public netIdOf;
    mapping(bytes32 => address) public netIdOwner; // keccak256(netId) => wallet, keeps NetIDs unique
    address[] internal students;

    mapping(uint8 => mapping(uint8 => bool)) public presenting;
    mapping(uint8 => mapping(address => bool)) public checkedIn;
    mapping(uint8 => mapping(address => uint256)) public spent;
    mapping(uint8 => mapping(address => mapping(uint8 => uint256))) public alloc;
    mapping(uint8 => mapping(uint8 => uint256)) public teamTokens;
    mapping(uint8 => mapping(uint8 => uint256)) public teamVotesX1000;
    mapping(uint8 => mapping(uint8 => uint256)) public teamVoters;
    mapping(uint8 => mapping(address => uint256)) public questionCount;
    mapping(uint8 => Question[]) internal questions;

    // ------------------------------------------------------------------ events
    event Registered(address indexed student, uint8 team, string netId);
    event SessionStarted(uint8 indexed session, uint8[] teams);
    event SessionEnded(uint8 indexed session);
    event CheckInToggled(uint8 indexed session, bool open);
    event CheckedIn(uint8 indexed session, address indexed student);
    event Allocated(uint8 indexed session, address indexed voter, uint8 indexed team, uint256 tokens);
    event QuestionAsked(uint8 indexed session, uint8 indexed team, uint256 index);
    event OwnershipTransferred(address indexed from, address indexed to);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only the TA can do this");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function isLive(uint8 s) public view returns (bool) {
        return s != 0 && s == currentSession;
    }

    // ------------------------------------------------------------------ token
    /// @notice Tokens left this session. Becomes 0 when the session ends (tokens expire).
    function balanceOf(address a) public view returns (uint256) {
        uint8 s = currentSession;
        if (s == 0 || !checkedIn[s][a]) return 0;
        return TOKENS_PER_SESSION - spent[s][a];
    }

    function totalSupply() external view returns (uint256 t) {
        uint8 s = currentSession;
        if (s == 0) return 0;
        address[] storage A = sessions[s].attendees;
        for (uint256 i = 0; i < A.length; i++) t += TOKENS_PER_SESSION - spent[s][A[i]];
    }

    function transfer(address, uint256) external pure returns (bool) {
        revert("Tokens can only be spent as votes");
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external pure returns (bool) {
        revert("Tokens are not transferable");
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert("Tokens are not transferable");
    }

    // ------------------------------------------------------------------ students
    /// @notice Register with your team number and NetID (lowercase, e.g. "xy1234"). Needs your own Sepolia ETH.
    function register(uint8 team, string calldata netId) external {
        require(team >= 1 && team <= MAX_TEAM, "Invalid team number");
        require(teamOf[msg.sender] == 0, "Already registered");
        require(_validNetId(netId), "NetID must be lowercase letters and digits, e.g. xy1234");
        require(netIdOwner[keccak256(bytes(netId))] == address(0), "This NetID is already registered");
        _register(msg.sender, team, netId);
    }

    /// @notice Check in with the code shown in class while token collection is open. Gives you 10 tokens.
    function checkIn(uint8 s, string calldata code) external {
        require(isLive(s), "This session is not live");
        Session storage S = sessions[s];
        require(S.checkInOpen, "Token collection is closed");
        require(teamOf[msg.sender] != 0, "Register first");
        require(!checkedIn[s][msg.sender], "Already checked in");
        require(keccak256(bytes(code)) == codeHash[s], "Wrong code");
        _checkIn(s, msg.sender);
    }

    /// @notice Spend tokens on presenting teams. Can be called more than once while the session is live.
    ///         Max 10 tokens on one team per session; votes = sqrt(tokens on that team).
    function allocate(uint8 s, uint8[] calldata teams, uint256[] calldata amounts) external {
        require(teams.length == amounts.length, "Length mismatch");
        require(isLive(s), "Voting is closed");
        require(checkedIn[s][msg.sender], "Check in first");
        uint8 own = teamOf[msg.sender];
        uint256 total;
        for (uint256 i = 0; i < teams.length; i++) {
            uint8 t = teams[i];
            uint256 amt = amounts[i];
            if (amt == 0) continue;
            require(presenting[s][t], "Team is not presenting this session");
            require(t != own, "You cannot vote for your own team");
            uint256 oldA = alloc[s][msg.sender][t];
            uint256 newA = oldA + amt;
            require(newA <= TOKENS_PER_SESSION, "Max 10 tokens per team");
            alloc[s][msg.sender][t] = newA;
            teamTokens[s][t] += amt;
            teamVotesX1000[s][t] = teamVotesX1000[s][t] + _sqrtX1000(newA) - _sqrtX1000(oldA);
            if (oldA == 0) teamVoters[s][t] += 1;
            total += amt;
            emit Allocated(s, msg.sender, t, amt);
        }
        uint256 used = spent[s][msg.sender] + total;
        require(used <= TOKENS_PER_SESSION, "Not enough tokens");
        spent[s][msg.sender] = used;
        emit Transfer(msg.sender, address(0), total);
    }

    function ask(uint8 s, uint8 team, string calldata text) external {
        require(isLive(s), "Session is closed");
        require(checkedIn[s][msg.sender], "Check in first");
        require(presenting[s][team], "Team is not presenting this session");
        require(team != teamOf[msg.sender], "Ask other teams");
        uint256 len = bytes(text).length;
        require(len >= 5 && len <= 600, "Question must be 5-600 characters");
        questions[s].push(Question(msg.sender, team, text));
        questionCount[s][msg.sender] += 1;
        emit QuestionAsked(s, team, questions[s].length - 1);
    }

    // ------------------------------------------------------------------ owner
    /// @notice Start a session: sets the presenting teams and the check-in code, and opens token collection.
    ///         Only one session can be live at a time, and each session can be started once.
    function startSession(uint8 s, uint8[] calldata teams, bytes32 hash) external onlyOwner {
        require(s >= 1 && s <= NUM_SESSIONS, "Session must be 1-5");
        require(currentSession == 0, "End the live session first");
        Session storage S = sessions[s];
        require(!S.started, "Session already started");
        require(teams.length > 0, "Add presenting teams");
        for (uint256 i = 0; i < teams.length; i++) {
            require(teams[i] >= 1 && teams[i] <= MAX_TEAM, "Invalid team number");
            require(!presenting[s][teams[i]], "Duplicate team");
            presenting[s][teams[i]] = true;
            S.teams.push(teams[i]);
        }
        codeHash[s] = hash;
        S.started = true;
        S.checkInOpen = true;
        currentSession = s;
        emit SessionStarted(s, teams);
    }

    /// @notice Stop or reopen token collection, optionally with a new code (pass 0x0 to keep the code).
    function setCheckIn(uint8 s, bool open, bytes32 newHash) external onlyOwner {
        require(isLive(s), "Session is not live");
        sessions[s].checkInOpen = open;
        if (newHash != bytes32(0)) codeHash[s] = newHash;
        emit CheckInToggled(s, open);
    }

    /// @notice End the live session: voting and questions close and every unspent token expires.
    function endSession(uint8 s) external onlyOwner {
        require(isLive(s), "Session is not live");
        Session storage S = sessions[s];
        S.ended = true;
        S.checkInOpen = false;
        currentSession = 0;
        emit SessionEnded(s);
    }

    /// @notice Manually check in students while the session is live (e.g. a wallet problem in class).
    function checkInFor(uint8 s, address[] calldata addrs) external onlyOwner {
        require(isLive(s), "Session is not live");
        for (uint256 i = 0; i < addrs.length; i++) {
            require(teamOf[addrs[i]] != 0, "Student not registered");
            if (!checkedIn[s][addrs[i]]) _checkIn(s, addrs[i]);
        }
    }

    /// @notice Fix a student's team and/or NetID, or move a NetID to a new wallet (e.g. a lost wallet).
    ///         If the NetID belongs to another wallet, that wallet loses it (it keeps its team and history).
    function setStudent(address a, uint8 team, string calldata netId) external onlyOwner {
        require(team >= 1 && team <= MAX_TEAM, "Invalid team number");
        require(_validNetId(netId), "Invalid NetID");
        address prev = netIdOwner[keccak256(bytes(netId))];
        if (prev != address(0) && prev != a) netIdOf[prev] = "";
        _register(a, team, netId);
    }

    function transferOwnership(address to) external onlyOwner {
        require(to != address(0), "Zero address");
        emit OwnershipTransferred(owner, to);
        owner = to;
    }

    // ------------------------------------------------------------------ views
    function getSession(uint8 s)
        external
        view
        returns (bool started, bool checkInOpen, bool live, bool ended, uint8[] memory teams, uint256 attendeeCount)
    {
        Session storage S = sessions[s];
        return (S.started, S.checkInOpen, isLive(s), S.ended, S.teams, S.attendees.length);
    }

    function getAttendees(uint8 s) external view returns (address[] memory) {
        return sessions[s].attendees;
    }

    function getResults(uint8 s)
        external
        view
        returns (uint8[] memory teams, uint256[] memory tokens, uint256[] memory votesX1000, uint256[] memory voters)
    {
        teams = sessions[s].teams;
        tokens = new uint256[](teams.length);
        votesX1000 = new uint256[](teams.length);
        voters = new uint256[](teams.length);
        for (uint256 i = 0; i < teams.length; i++) {
            tokens[i] = teamTokens[s][teams[i]];
            votesX1000[i] = teamVotesX1000[s][teams[i]];
            voters[i] = teamVoters[s][teams[i]];
        }
    }

    function getQuestions(uint8 s)
        external
        view
        returns (address[] memory askers, uint8[] memory teams, string[] memory texts)
    {
        Question[] storage Q = questions[s];
        askers = new address[](Q.length);
        teams = new uint8[](Q.length);
        texts = new string[](Q.length);
        for (uint256 i = 0; i < Q.length; i++) {
            askers[i] = Q[i].asker;
            teams[i] = Q[i].team;
            texts[i] = Q[i].text;
        }
    }

    function getAlloc(uint8 s, address a) external view returns (uint8[] memory teams, uint256[] memory tokens) {
        teams = sessions[s].teams;
        tokens = new uint256[](teams.length);
        for (uint256 i = 0; i < teams.length; i++) tokens[i] = alloc[s][a][teams[i]];
    }

    /// @notice Valid ballot: checked in, tokens on every presenting team except your own, 2+ written questions.
    function ballotValid(uint8 s, address a) public view returns (bool) {
        if (!checkedIn[s][a]) return false;
        if (questionCount[s][a] < MIN_QUESTIONS) return false;
        uint8[] storage T = sessions[s].teams;
        uint8 own = teamOf[a];
        for (uint256 i = 0; i < T.length; i++) {
            if (T[i] == own) continue;
            if (alloc[s][a][T[i]] == 0) return false;
        }
        return true;
    }

    function getStudent(address a)
        external
        view
        returns (uint8 team, string memory netId, bool[5] memory attended, bool[5] memory valid, uint256[5] memory asked, uint256 balance)
    {
        team = teamOf[a];
        netId = netIdOf[a];
        for (uint8 s = 1; s <= NUM_SESSIONS; s++) {
            attended[s - 1] = checkedIn[s][a];
            valid[s - 1] = ballotValid(s, a);
            asked[s - 1] = questionCount[s][a];
        }
        balance = balanceOf(a);
    }

    function getStudents() external view returns (address[] memory addrs, uint8[] memory teams, string[] memory netIds) {
        addrs = students;
        teams = new uint8[](addrs.length);
        netIds = new string[](addrs.length);
        for (uint256 i = 0; i < addrs.length; i++) {
            teams[i] = teamOf[addrs[i]];
            netIds[i] = netIdOf[addrs[i]];
        }
    }

    // ------------------------------------------------------------------ internal
    function _register(address a, uint8 team, string calldata netId) internal {
        if (teamOf[a] == 0) students.push(a);
        string memory old = netIdOf[a];
        if (bytes(old).length > 0) delete netIdOwner[keccak256(bytes(old))];
        teamOf[a] = team;
        netIdOf[a] = netId;
        netIdOwner[keccak256(bytes(netId))] = a;
        emit Registered(a, team, netId);
    }

    /// 2-16 characters: a lowercase letter, then lowercase letters or digits.
    function _validNetId(string calldata id) internal pure returns (bool) {
        bytes calldata b = bytes(id);
        if (b.length < 2 || b.length > 16) return false;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            bool letter = c >= 0x61 && c <= 0x7a;
            bool digit = c >= 0x30 && c <= 0x39;
            if (!(letter || (digit && i > 0))) return false;
        }
        return true;
    }

    function _checkIn(uint8 s, address a) internal {
        checkedIn[s][a] = true;
        sessions[s].attendees.push(a);
        emit CheckedIn(s, a);
        emit Transfer(address(0), a, TOKENS_PER_SESSION);
    }

    /// sqrt(n) * 1000, n = 0..10
    function _sqrtX1000(uint256 n) internal pure returns (uint256) {
        uint16[11] memory t = [uint16(0), 1000, 1414, 1732, 2000, 2236, 2449, 2646, 2828, 3000, 3162];
        return t[n];
    }
}
