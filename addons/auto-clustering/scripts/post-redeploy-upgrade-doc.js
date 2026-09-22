var nodeType = "${nodes.sqldb.nodeType}",
    targetTag = "${event.params.tag}",
    pathsUrl = "${globals.path}/addons/upgrade-paths.json?_r=${fn.random}",
    paths, engine, docUrl;

if (!/mysql|percona|mariadb/.test(nodeType) || !targetTag) {
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

docUrl = engine.upgradeGuideUrl || engine.docUrl;
if (!docUrl) {
    return {result: 0};
}

return {
    result: 0,
    message: "Database node redeployed to " + targetTag + ". Review the official upgrade documentation: " + docUrl
};

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
            return engine;
        }
    }
    return null;
}
