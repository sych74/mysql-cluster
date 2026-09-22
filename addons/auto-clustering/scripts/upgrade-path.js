var MODE_DOC = "doc",
    mode = getParam("mode", "validate"),
    nodeType = "${nodes.sqldb.nodeType}",
    targetTag = "${event.params.tag:}",
    sequential = "${event.params.sequential:}",
    nodeCount = parseInt("${nodes.sqldb.length:1}", 10) || 1,
    scheme = String("${settings.scheme:slave}").toLowerCase(),
    currentVersion = "${nodes.sqldb.master.version:}" || "${nodes.sqldb.version:}",
    pathsUrl = "${globals.path}/addons/upgrade-paths.json?_r=${fn.random}",
    paths, engine;

if (!/mysql|percona|mariadb/.test(nodeType) || !targetTag) {
    return mode == MODE_DOC ? {result: 0, hasDoc: false} : {result: 0, allowed: true};
}

paths = loadJson(pathsUrl);
engine = paths && paths.engines ? getEngineConfig(nodeType, paths.engines) : null;

return mode == MODE_DOC ? describe() : validate();

function describe() {
    var guideUrl = engine ? schemeUrl(engine) || engine.upgradeGuideUrl || engine.docUrl : null;

    if (!guideUrl) return {result: 0, hasDoc: false};

    return {
        result: 0,
        hasDoc: true,
        message: "Database node redeployed to " + targetTag +
            ". Review the official upgrade documentation: " + guideUrl + topologyNote()
    };
}

function validate() {
    var current, target, strictRolling;

    if (nodeCount > 1 && sequential == "false") {
        return block("Redeploying all " + nodeCount + " database nodes at once breaks the cluster quorum " +
            "and causes full downtime. Enable sequential redeploy or redeploy the nodes one by one.");
    }

    if (!paths || !paths.engines) {
        return block("Unable to load upgrade path rules. Redeploy blocked for safety.");
    }

    if (!engine) {
        return block("Unsupported database engine for upgrade path validation.");
    }

    current = parseVersion(currentVersion);
    target = parseVersion(targetTag);

    if (!current) {
        return block("Unable to determine current database version. Redeploy blocked for safety.");
    }

    if (!target) {
        return block("Unable to determine the target version from tag '" + targetTag +
            "'. Redeploy blocked for safety.");
    }

    if (compareVersions(current, target) > 0) {
        return block("Downgrade from " + currentVersion + " to " + targetTag + " is not supported. See " +
            docUrl() + " for supported paths.");
    }

    strictRolling = isStrictRolling(scheme, engine);

    if (strictRolling && findSkippedLts(current, target, engine.ltsLadder || [])) {
        return block(buildUpgradeErrorMessage(current));
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

function getEngineConfig(dbNodeType, engines) {
    var key, item;
    for (key in engines) {
        if (!engines.hasOwnProperty(key)) continue;
        item = engines[key];
        if (item.nodeTypeMatch && new RegExp(item.nodeTypeMatch).test(dbNodeType)) {
            return item;
        }
    }
    return null;
}

function schemeUrl(engineConfig) {
    return engineConfig.schemeDocUrls ? engineConfig.schemeDocUrls[scheme] : null;
}

function docUrl() {
    return schemeUrl(engine) || engine.docUrl;
}

// Both MySQL and MariaDB require replicas to be upgraded before the source: a source
// running a later release cannot replicate to a replica running an earlier one.
function topologyNote() {
    var note;

    if (scheme == "slave") {
        note = " Upgrade every replica before the source: a newer source cannot replicate to an older replica.";
    } else if (scheme == "master") {
        note = " In a primary-primary topology stop replication towards the primary that is not upgraded yet: " +
            "a newer source cannot replicate to an older replica.";
    } else {
        return "";
    }

    return engine.replicationUrl ? note + " See " + engine.replicationUrl + "." : note;
}

// Accepts both a bare version ("11.4.4") and a full image tag ("mariadb:11.4-jammy").
function parseVersion(value) {
    var match = String(value || "").replace(/^.*:/, "").match(/(\d+)\.(\d+)(?:\.(\d+))?/);
    return match ? {major: +match[1], minor: +match[2], patch: match[3] ? +match[3] : 0} : null;
}

function parseSeries(version) {
    var match = String(version).match(/^(\d+)\.(\d+)/);
    return match ? {major: +match[1], minor: +match[2]} : null;
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

function isStrictRolling(topology, engineConfig) {
    if (engineConfig.alwaysStrictRolling) return true;
    if (!engineConfig.strictRollingSchemes) return false;
    return engineConfig.strictRollingSchemes.indexOf(topology) >= 0;
}

// An upgrade is supported only when no LTS series sits strictly between the current
// and the target version, i.e. no LTS series gets skipped over.
function findSkippedLts(cur, tgt, ladder) {
    var i, item;
    for (i = 0; i < ladder.length; i++) {
        item = parseSeries(ladder[i]);
        if (item && compareSeries(cur, item) < 0 && compareSeries(item, tgt) < 0) return item;
    }
    return null;
}

function nextLadderStep(cur, ladder) {
    var i, item;
    for (i = 0; i < ladder.length; i++) {
        item = parseSeries(ladder[i]);
        if (item && compareSeries(cur, item) > 0) continue;
        if (item && compareSeries(cur, item) < 0) return item;
    }
    return null;
}

function buildUpgradeErrorMessage(current) {
    var msg = "Upgrade from " + currentVersion + " to " + targetTag + " is not supported.",
        hint = engine.schemeHints ? engine.schemeHints[scheme] : null,
        nextStep = nextLadderStep(current, engine.ltsLadder || []);

    if (hint) msg += " " + hint;
    if (nextStep) msg += " Upgrade to " + nextStep.major + "." + nextStep.minor + " first.";

    return msg + " See " + docUrl() + " for supported paths.";
}
