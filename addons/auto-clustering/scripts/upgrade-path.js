var nodeType = "${nodes.sqldb.nodeType}",
    targetTag = "${event.params.tag:}",
    targetNodeId = "${event.params.nodeId:}",
    nodeGroup = "${nodes.sqldb.master.nodeGroup:sqldb}",
    envName = "${env.envName}",
    scheme = String("${settings.scheme:slave}").toLowerCase(),
    VERSION_CMD = "(command -v mariadbd >/dev/null && mariadbd --version || mysqld --version) 2>/dev/null | " +
        "grep -oE 'Ver [0-9]+\\.[0-9]+\\.[0-9]+' | head -n1 | cut -d' ' -f2",
    pathsUrl = "${globals.path}/addons/upgrade-paths.json?_r=${fn.random}",
    paths, engine;

if (!/mysql|percona|mariadb/.test(nodeType) || !targetTag) {
    return {result: 0, allowed: true};
}

paths = loadJson(pathsUrl);
engine = paths && paths.engines ? getEngineConfig(nodeType, paths.engines) : null;

return validate();

function validate() {
    var target = parseVersion(targetTag),
        nodes, resp, i;

    if (!target) {
        return block("Unable to determine the target version from tag '" + targetTag +
            "'. Redeploy blocked for safety.");
    }

    nodes = getTargetNodes();
    if (!nodes) {
        return block("Unable to get the database nodes. Redeploy blocked for safety.");
    }

    for (i = 0; i < nodes.length; i++) {
        resp = validateNode(nodes[i], target);
        if (!resp.allowed) return resp;
    }

    return {result: 0, allowed: true};
}

// The upgrade path depends on the version the data directory of every redeployed node was last
// started with, which may differ between nodes after an interrupted sequential redeploy.
function getTargetNodes() {
    var resp = api.env.control.GetEnvInfo(envName, session),
        nodes = [], i, n;

    if (resp.result != 0) return null;

    for (i = 0, n = resp.nodes; i < n.length; i++) {
        if (n[i].nodeGroup != nodeGroup) continue;
        if (targetNodeId && String(n[i].id) != targetNodeId) continue;
        nodes.push(n[i]);
    }

    return nodes;
}

// The installed server binary is the most reliable source of the node version; the version
// stored in the node metadata is used only when the node does not respond.
function getNodeVersion(node) {
    var resp = api.env.control.ExecCmdById(envName, session, node.id, toJSON([{command: VERSION_CMD}]), true, "root"),
        out = resp.result == 0 && resp.responses && resp.responses[0] ? String(resp.responses[0].out || "") : "";

    return parseVersion(out) ? out.replace(/\s+/g, "") : String(node.version || "");
}

function validateNode(node, target) {
    var currentVersion = getNodeVersion(node),
        current = parseVersion(currentVersion),
        skipped;

    if (!current) {
        return block("Unable to determine the database version of node " + node.id +
            ". Redeploy blocked for safety.");
    }

    // A downgrade is never allowed, even a patch rollback within the same series: the data directory
    // may already be upgraded by the newer server. The check needs no upgrade path rules.
    if (compareVersions(current, target) > 0) {
        return block("Downgrade from " + currentVersion + " to " + targetTag + " is not supported." +
            (engine ? " See the " + link("supported upgrade paths", engine.docUrl) + "." : ""));
    }

    // Patch upgrades within a single release series are supported by every engine and need no
    // upgrade path rules, which keeps security patches installable when the rules are unreachable.
    if (compareSeries(current, target) === 0) {
        return {result: 0, allowed: true};
    }

    if (!paths || !paths.engines) {
        return block("Unable to load the upgrade path rules, so the redeploy to " + targetTag +
            " is blocked for safety. A redeploy within the current " + series(current) +
            " series is still allowed.");
    }

    if (!engine) {
        return block("Unsupported database engine for upgrade path validation.");
    }

    skipped = isStrict(engine) ? findSkippedLts(current, target, engine.ltsLadder || []) : null;

    if (skipped) {
        return block(buildUpgradeErrorMessage(currentVersion, skipped));
    }

    return {result: 0, allowed: true};
}

function block(message) {
    return {result: 0, allowed: false, message: message};
}

function loadJson(url) {
    var conn, line, body = "", input;

    try {
        conn = new java.net.URL(url).openConnection();
        conn.setUseCaches(false);
        conn.setConnectTimeout(10000);
        conn.setReadTimeout(10000);
        input = new java.io.BufferedReader(new java.io.InputStreamReader(conn.getInputStream(), "UTF-8"));
        while ((line = input.readLine()) !== null) {
            body += line;
        }
        input.close();
        return JSON.parse(body);
    } catch (e) {
        return null;
    }
}

// Engines are keyed by the name their node type contains: mysql, perconadb, mariadb-dockerized.
function getEngineConfig(dbNodeType, engines) {
    var key;
    for (key in engines) {
        if (engines.hasOwnProperty(key) && dbNodeType.indexOf(key) >= 0) return engines[key];
    }
    return null;
}

function link(text, url) {
    return "[" + text + "](" + url + ")";
}

// Accepts a bare version ("11.4.4"), a series ("11.4") and a tag prefixed with the image name
// ("mariadb:11.4.4").
function parseVersion(value) {
    var match = String(value || "").replace(/^.*:/, "").match(/(\d+)\.(\d+)(?:\.(\d+))?/);
    return match ? {major: +match[1], minor: +match[2], patch: match[3] ? +match[3] : 0} : null;
}

function series(version) {
    return version.major + "." + version.minor;
}

function compareSeries(a, b) {
    if (a.major !== b.major) return a.major < b.major ? -1 : 1;
    if (a.minor !== b.minor) return a.minor < b.minor ? -1 : 1;
    return 0;
}

function compareVersions(a, b) {
    var cmp = compareSeries(a, b);
    if (cmp !== 0) return cmp;
    if (a.patch !== b.patch) return a.patch < b.patch ? -1 : 1;
    return 0;
}

// The LTS ladder applies to every scheme unless the engine limits it to some schemes only
// (MariaDB supports skipping versions everywhere except a Galera rolling upgrade).
function isStrict(engineConfig) {
    return !engineConfig.strictSchemes || engineConfig.strictSchemes.indexOf(scheme) >= 0;
}

// An upgrade is supported only when no LTS series sits strictly between the current and the
// target version. The ladder is sorted, so the first skipped series is the next required step.
function findSkippedLts(cur, tgt, ladder) {
    var i, item;
    for (i = 0; i < ladder.length; i++) {
        item = parseVersion(ladder[i]);
        if (item && compareSeries(cur, item) < 0 && compareSeries(item, tgt) < 0) return item;
    }
    return null;
}

function buildUpgradeErrorMessage(currentVersion, nextStep) {
    var msg = "Upgrade from " + currentVersion + " to " + targetTag + " is not supported.",
        hint = engine.schemeHints ? engine.schemeHints[scheme] : null;

    if (hint) msg += " " + hint;
    // The intermediate series may be no longer offered as a tag, so the logical dump is suggested
    // as the way out that is always available.
    msg += " Upgrade to the latest " + series(nextStep) + " release first, or, if that version is not " +
        "available, migrate the data with a logical dump into a new environment.";

    return msg + " See the " + link("supported upgrade paths", engine.docUrl) + ".";
}
