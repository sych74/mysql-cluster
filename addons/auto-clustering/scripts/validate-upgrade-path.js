var currentVersion = "${nodes.sqldb.version}",
    targetTag = "${event.params.tag}",
    nodeType = "${nodes.sqldb.nodeType}",
    scheme = "${env.SCHEME:slave}",
    versionCmp = "${fn.compare([nodes.sqldb.version], ${event.params.tag})}",
    pathsUrl = "${globals.path}/addons/upgrade-paths.json?_r=${fn.random}",
    paths, engine, docUrl;

if (!/mysql|percona|mariadb/.test(nodeType) || !currentVersion || !targetTag) {
    return {result: 0};
}

paths = loadJson(pathsUrl);
if (!paths || !paths.engines) {
    return {result: 0};
}

engine = getEngineConfig(nodeType, paths.engines);
if (!engine) {
    return {result: 0};
}

docUrl = engine.docUrl;

if (versionCmp === "0") {
    return {result: 0};
}

if (versionCmp === "1") {
    return {
        result: "warning",
        message: "Downgrade from " + currentVersion + " to " + targetTag + " is not supported. See " + docUrl + " for supported paths."
    };
}

if (!isAllowedUpgrade(currentVersion, targetTag, nodeType, scheme, engine)) {
    return {
        result: "warning",
        message: buildUpgradeErrorMessage(currentVersion, targetTag, nodeType, scheme, engine)
    };
}

return {result: 0};

function loadJson(url) {
    var conn, reader, line, body = "", input;

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
    var key, engine;
    for (key in engines) {
        if (!engines.hasOwnProperty(key)) continue;
        engine = engines[key];
        if (engine.nodeTypeMatch && new RegExp(engine.nodeTypeMatch).test(dbNodeType)) {
            engine.id = key;
            return engine;
        }
    }
    return null;
}

function parseSeries(version) {
    var match = String(version).match(/^(\d+)\.(\d+)/);
    return match ? {major: +match[1], minor: +match[2]} : null;
}

function seriesEqual(a, b) {
    return a.major === b.major && a.minor === b.minor;
}

function compareSeries(a, b) {
    if (a.major !== b.major) return a.major < b.major ? -1 : 1;
    if (a.minor !== b.minor) return a.minor < b.minor ? -1 : 1;
    return 0;
}

function isKnownMajor(major, ladder) {
    var i, item;
    for (i = 0; i < ladder.length; i++) {
        item = parseSeries(ladder[i]);
        if (item && item.major === major) return true;
    }
    return false;
}

function isOnLadder(cur, ladder) {
    var i, item;
    for (i = 0; i < ladder.length; i++) {
        item = parseSeries(ladder[i]);
        if (item && seriesEqual(cur, item)) return true;
    }
    return false;
}

function findNextLadderStep(cur, ladder) {
    var i, item;
    for (i = 0; i < ladder.length; i++) {
        item = parseSeries(ladder[i]);
        if (!item) continue;
        if (seriesEqual(cur, item)) {
            return i + 1 < ladder.length ? parseSeries(ladder[i + 1]) : null;
        }
        if (compareSeries(cur, item) < 0) {
            return item;
        }
    }
    return null;
}

function isStrictRolling(topology, engine) {
    if (engine.alwaysStrictRolling) return true;
    if (!engine.strictRollingSchemes || !engine.strictRollingSchemes.length) return false;
    return engine.strictRollingSchemes.indexOf(String(topology || "").toLowerCase()) >= 0;
}

function isAllowedSeriesUpgrade(cur, tgt, ladder, strictRolling) {
    var cmp, next, ltsTarget;

    if (!cur || !tgt) return true;
    if (!isKnownMajor(cur.major, ladder) || !isKnownMajor(tgt.major, ladder)) return false;
    if (seriesEqual(cur, tgt)) return true;

    cmp = compareSeries(cur, tgt);
    if (cmp > 0) return false;
    if (!strictRolling) return true;

    if (isOnLadder(cur, ladder) && isOnLadder(tgt, ladder)) {
        next = findNextLadderStep(cur, ladder);
        return next && seriesEqual(next, tgt);
    }

    if (isOnLadder(cur, ladder) && !isOnLadder(tgt, ladder)) {
        next = findNextLadderStep(cur, ladder);
        if (!next) return false;
        return compareSeries(cur, tgt) < 0 && compareSeries(tgt, next) < 0;
    }

    if (!isOnLadder(cur, ladder) && isOnLadder(tgt, ladder)) {
        next = findNextLadderStep(cur, ladder);
        return next && seriesEqual(next, tgt);
    }

    if (!isOnLadder(cur, ladder) && !isOnLadder(tgt, ladder)) {
        return cur.major === tgt.major && compareSeries(cur, tgt) < 0;
    }

    return false;
}

function isAllowedUpgrade(currentVersion, nextVersion, dbNodeType, topology, engineConfig) {
    return isAllowedSeriesUpgrade(
        parseSeries(currentVersion),
        parseSeries(nextVersion),
        engineConfig.ltsLadder || [],
        isStrictRolling(topology, engineConfig)
    );
}

function buildUpgradeErrorMessage(currentVersion, targetTag, dbNodeType, topology, engineConfig) {
    var msg = "Upgrade from " + currentVersion + " to " + targetTag + " is not supported.",
        nextStep, cur;

    if (/mariadb/.test(dbNodeType) && isStrictRolling(topology, engineConfig)) {
        cur = parseSeries(currentVersion);
        nextStep = formatSeries(findNextLadderStep(cur, engineConfig.ltsLadder || []));
        if (engineConfig.galeraHint) {
            msg += " " + engineConfig.galeraHint;
        }
        if (nextStep) {
            msg += " Upgrade to " + nextStep + " first.";
        }
    }

    return msg + " See " + engineConfig.docUrl + " for supported paths.";
}

function formatSeries(series) {
    return series ? series.major + "." + series.minor : null;
}
