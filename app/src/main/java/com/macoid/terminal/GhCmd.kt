package com.macoid.terminal

import org.eclipse.jgit.lib.StoredConfig
import org.eclipse.jgit.storage.file.FileBasedConfig
import org.eclipse.jgit.storage.file.FileRepositoryBuilder
import org.eclipse.jgit.util.FS
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Token store + REST helper shared by gh and git. */
object Gh {
    private val tokenFile: File get() = File(System.getProperty("user.home") ?: ".", ".config/macoid/github_token")

    fun token(): String? =
        System.getenv("GH_TOKEN") ?: System.getenv("GITHUB_TOKEN")
            ?: tokenFile.takeIf { it.exists() }?.readText()?.trim()?.ifEmpty { null }

    fun saveToken(t: String) {
        tokenFile.parentFile?.mkdirs()
        tokenFile.writeText(t.trim() + "\n")
        tokenFile.setReadable(false, false); tokenFile.setReadable(true, true)
    }

    fun clearToken() { tokenFile.delete() }

    fun api(method: String, path: String, body: String? = null, accept: String = "application/vnd.github+json", follow: Boolean = true): Http.Resp {
        val url = if (path.startsWith("http")) path else "https://api.github.com/" + path.trimStart('/')
        val h = LinkedHashMap<String, String>()
        h["Accept"] = accept
        h["User-Agent"] = "macoid-gh"
        h["X-GitHub-Api-Version"] = "2022-11-28"
        token()?.let { h["Authorization"] = "Bearer $it" }
        if (body != null) h["Content-Type"] = "application/json"
        return Http.request(method, url, h, body?.toByteArray(), follow)
    }

    fun authHeaders(): Map<String, String> = mapOf(
        "Authorization" to "Bearer ${token() ?: ""}", "Accept" to "application/vnd.github+json", "User-Agent" to "macoid-gh"
    )

    /** owner/repo of the 'origin' remote of the repository in the current directory. */
    fun currentRepo(): String? {
        val b = FileRepositoryBuilder().readEnvironment().findGitDir(Cli.cwd())
        if (b.gitDir == null) return null
        val url = b.build().config.getString("remote", "origin", "url") ?: return null
        val m = Regex("github\\.com[:/]([^/]+)/([^/]+?)(\\.git)?/?$").find(url) ?: return null
        return "${m.groupValues[1]}/${m.groupValues[2]}"
    }
}

object GhCmd {
    class Fail(msg: String) : Exception(msg)

    fun run(a: List<String>): Int = try {
        dispatch(a)
    } catch (e: Fail) {
        System.err.println(e.message); 1
    }

    private fun need(): String = Gh.token() ?: throw Fail("gh: not logged in. Run: gh auth login   (needs a GitHub token with 'repo' and 'workflow' scopes)")

    private fun ok(r: Http.Resp, what: String): JSONObject? {
        if (r.code >= 400) {
            val msg = try { JSONObject(r.body).optString("message", r.body) } catch (e: Exception) { r.body }
            throw Fail("gh: $what failed (HTTP ${r.code}): $msg")
        }
        return try { if (r.body.trimStart().startsWith("{")) JSONObject(r.body) else null } catch (e: Exception) { null }
    }

    private fun arr(r: Http.Resp, what: String): JSONArray {
        ok(r, what)
        return JSONArray(r.body)
    }

    private fun repoArg(o: Opts): String =
        o.v("-R", "--repo") ?: Gh.currentRepo() ?: throw Fail("gh: not in a GitHub repository; pass -R owner/repo")

    private fun dispatch(a: List<String>): Int {
        val cmd = a.firstOrNull() ?: return help()
        val rest = a.drop(1)
        return when (cmd) {
            "auth" -> auth(rest)
            "whoami" -> { println(user().optString("login")); 0 }
            "repo" -> repo(rest)
            "issue" -> issue(rest)
            "pr" -> pr(rest)
            "run" -> runCmd(rest)
            "workflow" -> workflow(rest)
            "release" -> release(rest)
            "search" -> search(rest)
            "api" -> api(rest)
            "--version", "version" -> { println("gh version 2.40.0 (Macoid)"); 0 }
            else -> help()
        }
    }

    private fun help(): Int {
        println("gh - GitHub CLI for Macoid\n")
        println("  gh auth login|status|logout|token")
        println("  gh repo create|list|view|clone|delete|fork")
        println("  gh issue list|create|view|close   gh pr list|create|view|merge|close|checkout")
        println("  gh run list|watch|view|download   gh workflow list|run   gh release create|list")
        println("  gh search repos <query>           gh api <endpoint> [-X METHOD] [-f key=value] [-q .path]")
        return 0
    }

    private fun user(): JSONObject = ok(Gh.api("GET", "user"), "fetching user") ?: JSONObject()

    // ---------- auth ----------

    private fun auth(a: List<String>): Int {
        when (a.firstOrNull()) {
            "login" -> {
                val o = Opts(a.drop(1), setOf("-t", "--token"))
                var t = o.v("-t", "--token")
                if (t == null) {
                    if (!o.has("--with-token")) {
                        System.err.println("Create a token at https://github.com/settings/tokens (scopes: repo, workflow, read:org)")
                        System.err.print("Paste your token: "); System.err.flush()
                    }
                    t = readLine()?.trim()
                }
                if (t.isNullOrEmpty()) throw Fail("gh: empty token")
                Gh.saveToken(t)
                val u = user()
                println("Logged in to github.com as ${u.optString("login")}")
                // make commits work out of the box
                val home = File(System.getProperty("user.home") ?: ".")
                val cfg: StoredConfig = FileBasedConfig(File(home, ".gitconfig"), FS.DETECTED).also { it.load() }
                if (cfg.getString("user", null, "name").isNullOrBlank()) {
                    cfg.setString("user", null, "name", u.optString("name").ifBlank { u.optString("login") })
                    cfg.setString("user", null, "email", u.optString("email").ifBlank { "${u.optLong("id")}+${u.optString("login")}@users.noreply.github.com" })
                    cfg.save()
                    println("Set git user.name / user.email from your GitHub profile.")
                }
                return 0
            }
            "status" -> {
                if (Gh.token() == null) { System.err.println("You are not logged in. Run: gh auth login"); return 1 }
                val r = Gh.api("GET", "user")
                if (r.code != 200) { System.err.println("Token is invalid (HTTP ${r.code})"); return 1 }
                println("Logged in to github.com as ${JSONObject(r.body).optString("login")}")
                return 0
            }
            "logout" -> { Gh.clearToken(); println("Logged out."); return 0 }
            "token" -> { println(need()); return 0 }
            else -> throw Fail("usage: gh auth login|status|logout|token")
        }
    }

    // ---------- repo ----------

    private fun repo(a: List<String>): Int {
        need()
        val sub = a.firstOrNull() ?: throw Fail("usage: gh repo create|list|view|clone|delete|fork")
        val o = Opts(a.drop(1), setOf("-d", "--description", "-s", "--source", "-L", "--limit", "--remote", "-R", "--repo"))
        when (sub) {
            "create" -> {
                val name = o.pos.firstOrNull() ?: Cli.cwd().name
                val body = JSONObject().put("name", name).put("private", !o.has("--public"))
                o.v("-d", "--description")?.let { body.put("description", it) }
                val j = ok(Gh.api("POST", "user/repos", body.toString()), "creating repository")!!
                println(j.getString("html_url"))
                val src = o.v("-s", "--source")
                if (src != null) {
                    val dir = Cli.res(src)
                    val b = FileRepositoryBuilder().readEnvironment().findGitDir(dir)
                    if (b.gitDir != null) {
                        val cfg = b.build().config
                        val rn = o.v("--remote") ?: "origin"
                        cfg.setString("remote", rn, "url", j.getString("clone_url"))
                        cfg.setString("remote", rn, "fetch", "+refs/heads/*:refs/remotes/$rn/*")
                        cfg.save()
                        println("Added remote $rn")
                        if (o.has("--push")) return GitCmd.run(listOf("-C", dir.path, "push", "-u", rn))
                    }
                }
                if (o.has("--clone")) return GitCmd.run(listOf("clone", j.getString("clone_url")))
            }
            "list" -> {
                val owner = o.pos.firstOrNull()
                val path = if (owner == null) "user/repos?per_page=${o.v("-L", "--limit") ?: "30"}&sort=updated" else "users/$owner/repos?per_page=${o.v("-L", "--limit") ?: "30"}"
                val l = arr(Gh.api("GET", path), "listing repositories")
                for (i in 0 until l.length()) { val r = l.getJSONObject(i); println("${r.getString("full_name")}\t${if (r.optBoolean("private")) "private" else "public"}\t${r.optString("description", "")}") }
            }
            "view" -> {
                val name = o.pos.firstOrNull() ?: Gh.currentRepo() ?: throw Fail("usage: gh repo view owner/repo")
                val r = ok(Gh.api("GET", "repos/$name"), "viewing repository")!!
                println("${r.getString("full_name")}\n${r.optString("description", "")}\n")
                println("stars: ${r.optInt("stargazers_count")}  forks: ${r.optInt("forks_count")}  default branch: ${r.optString("default_branch")}")
                println(r.getString("html_url"))
            }
            "clone" -> {
                val name = o.pos.firstOrNull() ?: throw Fail("usage: gh repo clone owner/repo [dir]")
                val full = if (name.contains('/')) name else "${user().getString("login")}/$name"
                return GitCmd.run(listOf("clone", "https://github.com/$full.git") + o.pos.drop(1))
            }
            "delete" -> {
                val name = o.pos.firstOrNull() ?: throw Fail("usage: gh repo delete owner/repo --yes")
                if (!o.has("--yes")) throw Fail("gh: this is destructive; re-run with --yes to confirm")
                ok(Gh.api("DELETE", "repos/$name"), "deleting repository"); println("Deleted $name")
            }
            "fork" -> {
                val name = o.pos.firstOrNull() ?: Gh.currentRepo() ?: throw Fail("usage: gh repo fork owner/repo")
                val j = ok(Gh.api("POST", "repos/$name/forks", "{}"), "forking")!!
                println(j.optString("html_url"))
            }
            else -> throw Fail("usage: gh repo create|list|view|clone|delete|fork")
        }
        return 0
    }

    // ---------- issues / PRs ----------

    private fun issue(a: List<String>): Int {
        need()
        val o = Opts(a.drop(1), setOf("-R", "--repo", "-t", "--title", "-b", "--body", "-l", "--label", "-s", "--state", "-L", "--limit"))
        val repo = repoArg(o)
        when (a.firstOrNull()) {
            "list" -> {
                val l = arr(Gh.api("GET", "repos/$repo/issues?state=${o.v("-s", "--state") ?: "open"}&per_page=${o.v("-L", "--limit") ?: "30"}"), "listing issues")
                for (i in 0 until l.length()) { val x = l.getJSONObject(i); if (!x.has("pull_request")) println("#${x.getInt("number")}\t${x.getString("state")}\t${x.getString("title")}") }
            }
            "create" -> {
                val b = JSONObject().put("title", o.v("-t", "--title") ?: throw Fail("gh: --title is required"))
                o.v("-b", "--body")?.let { b.put("body", it) }
                o.all("-l", "--label").takeIf { it.isNotEmpty() }?.let { b.put("labels", JSONArray(it)) }
                println(ok(Gh.api("POST", "repos/$repo/issues", b.toString()), "creating issue")!!.getString("html_url"))
            }
            "view" -> {
                val x = ok(Gh.api("GET", "repos/$repo/issues/${o.pos.first()}"), "viewing issue")!!
                println("#${x.getInt("number")} ${x.getString("title")} [${x.getString("state")}]\n\n${x.optString("body", "")}")
            }
            "close" -> { ok(Gh.api("PATCH", "repos/$repo/issues/${o.pos.first()}", "{\"state\":\"closed\"}"), "closing issue"); println("Closed #${o.pos.first()}") }
            else -> throw Fail("usage: gh issue list|create|view|close")
        }
        return 0
    }

    private fun pr(a: List<String>): Int {
        need()
        val o = Opts(a.drop(1), setOf("-R", "--repo", "-t", "--title", "-b", "--body", "-B", "--base", "-H", "--head", "-s", "--state", "-L", "--limit"))
        val repo = repoArg(o)
        when (a.firstOrNull()) {
            "list" -> {
                val l = arr(Gh.api("GET", "repos/$repo/pulls?state=${o.v("-s", "--state") ?: "open"}&per_page=${o.v("-L", "--limit") ?: "30"}"), "listing pull requests")
                for (i in 0 until l.length()) { val x = l.getJSONObject(i); println("#${x.getInt("number")}\t${x.getJSONObject("head").getString("ref")}\t${x.getString("title")}") }
            }
            "create" -> {
                val head = o.v("-H", "--head") ?: run {
                    val b = FileRepositoryBuilder().readEnvironment().findGitDir(Cli.cwd()).build(); b.branch
                }
                val base = o.v("-B", "--base") ?: ok(Gh.api("GET", "repos/$repo"), "reading repository")!!.getString("default_branch")
                val b = JSONObject().put("title", o.v("-t", "--title") ?: head).put("head", head).put("base", base).put("body", o.v("-b", "--body") ?: "")
                println(ok(Gh.api("POST", "repos/$repo/pulls", b.toString()), "creating pull request")!!.getString("html_url"))
            }
            "view" -> {
                val x = ok(Gh.api("GET", "repos/$repo/pulls/${o.pos.first()}"), "viewing pull request")!!
                println("#${x.getInt("number")} ${x.getString("title")} [${x.getString("state")}]\n${x.getString("html_url")}\n\n${x.optString("body", "")}")
            }
            "merge" -> {
                val method = if (o.has("--squash")) "squash" else if (o.has("--rebase")) "rebase" else "merge"
                ok(Gh.api("PUT", "repos/$repo/pulls/${o.pos.first()}/merge", "{\"merge_method\":\"$method\"}"), "merging"); println("Merged #${o.pos.first()}")
            }
            "close" -> { ok(Gh.api("PATCH", "repos/$repo/pulls/${o.pos.first()}", "{\"state\":\"closed\"}"), "closing"); println("Closed #${o.pos.first()}") }
            "checkout" -> {
                val n = o.pos.first()
                var rc = GitCmd.run(listOf("fetch", "origin", "pull/$n/head:pr-$n"))
                if (rc == 0) rc = GitCmd.run(listOf("checkout", "pr-$n"))
                return rc
            }
            else -> throw Fail("usage: gh pr list|create|view|merge|close|checkout")
        }
        return 0
    }

    // ---------- Actions ----------

    private fun runCmd(a: List<String>): Int {
        need()
        val o = Opts(a.drop(1), setOf("-R", "--repo", "-L", "--limit", "--branch", "--wait", "-D", "--dir", "-n", "--name"))
        val repo = repoArg(o)
        when (a.firstOrNull()) {
            "list" -> {
                val br = o.v("--branch")?.let { "&branch=$it" } ?: ""
                val j = ok(Gh.api("GET", "repos/$repo/actions/runs?per_page=${o.v("-L", "--limit") ?: "20"}$br"), "listing runs")!!
                val l = j.getJSONArray("workflow_runs")
                for (i in 0 until l.length()) { val r = l.getJSONObject(i); println("${r.getLong("id")}\t${r.getString("status")}\t${r.optString("conclusion", "-")}\t${r.optString("name")}\t${r.optString("head_branch")}") }
            }
            // prints the newest run id for a branch, waiting for it to appear
            "latest" -> {
                val br = o.v("--branch") ?: throw Fail("gh run latest: --branch is required")
                val deadline = System.currentTimeMillis() + (o.v("--wait")?.toLongOrNull() ?: 60L) * 1000
                while (true) {
                    val j = ok(Gh.api("GET", "repos/$repo/actions/runs?branch=$br&per_page=1"), "listing runs")!!
                    val l = j.getJSONArray("workflow_runs")
                    if (l.length() > 0) { println(l.getJSONObject(0).getLong("id")); return 0 }
                    if (System.currentTimeMillis() > deadline) return 1
                    Thread.sleep(3000)
                }
            }
            "watch", "view" -> {
                val id = o.pos.firstOrNull() ?: throw Fail("usage: gh run watch <run-id>")
                val watch = a.first() == "watch"
                var last = ""
                while (true) {
                    val r = ok(Gh.api("GET", "repos/$repo/actions/runs/$id"), "reading run")!!
                    val st = r.getString("status")
                    val line = "$st ${r.optString("conclusion", "")}"
                    if (line != last) { System.err.println("[run $id] $line"); last = line }
                    if (st == "completed" || !watch) {
                        val jobs = ok(Gh.api("GET", "repos/$repo/actions/runs/$id/jobs"), "reading jobs")!!.getJSONArray("jobs")
                        for (i in 0 until jobs.length()) {
                            val jb = jobs.getJSONObject(i)
                            println("\n=== ${jb.getString("name")}: ${jb.optString("conclusion", jb.getString("status"))}")
                            if (o.has("--log") || o.has("--log-failed") || watch) {
                                val lg = Gh.api("GET", "repos/$repo/actions/jobs/${jb.getLong("id")}/logs", accept = "*/*", follow = false)
                                val text = if (lg.location != null) Http.request("GET", lg.location, emptyMap()).body else lg.body
                                println(text)
                            }
                        }
                        return if (r.optString("conclusion") == "success" || (!watch && st != "completed")) 0 else 1
                    }
                    Thread.sleep(5000)
                }
            }
            "download" -> {
                val id = o.pos.firstOrNull() ?: throw Fail("usage: gh run download <run-id> [-n name] [-D dir]")
                val dir = Cli.res(o.v("-D", "--dir") ?: ".")
                val l = ok(Gh.api("GET", "repos/$repo/actions/runs/$id/artifacts"), "listing artifacts")!!.getJSONArray("artifacts")
                if (l.length() == 0) { System.err.println("no artifacts for run $id"); return 1 }
                for (i in 0 until l.length()) {
                    val ar = l.getJSONObject(i)
                    val name = ar.getString("name")
                    if (o.v("-n", "--name") != null && o.v("-n", "--name") != name) continue
                    val zip = File(dir, "$name.zip")
                    Http.download(ar.getString("archive_download_url"), Gh.authHeaders(), zip)
                    Zips.extract(zip, File(dir, name)); zip.delete()
                    println("downloaded artifact '$name' -> ${File(dir, name).path}")
                }
            }
            else -> throw Fail("usage: gh run list|watch|view|download")
        }
        return 0
    }

    private fun workflow(a: List<String>): Int {
        need()
        val o = Opts(a.drop(1), setOf("-R", "--repo", "-f", "--field", "--ref"))
        val repo = repoArg(o)
        when (a.firstOrNull()) {
            "list" -> {
                val l = ok(Gh.api("GET", "repos/$repo/actions/workflows"), "listing workflows")!!.getJSONArray("workflows")
                for (i in 0 until l.length()) { val w = l.getJSONObject(i); println("${w.getString("name")}\t${w.getString("state")}\t${w.getLong("id")}") }
            }
            "run" -> {
                val wf = o.pos.firstOrNull() ?: throw Fail("usage: gh workflow run <file.yml> [-f k=v]")
                val ref = o.v("--ref") ?: ok(Gh.api("GET", "repos/$repo"), "reading repository")!!.getString("default_branch")
                val inputs = JSONObject(); o.all("-f", "--field").forEach { inputs.put(it.substringBefore('='), it.substringAfter('=', "")) }
                ok(Gh.api("POST", "repos/$repo/actions/workflows/$wf/dispatches", JSONObject().put("ref", ref).put("inputs", inputs).toString()), "dispatching workflow")
                println("Workflow $wf dispatched on $ref")
            }
            else -> throw Fail("usage: gh workflow list|run")
        }
        return 0
    }

    private fun release(a: List<String>): Int {
        need()
        val o = Opts(a.drop(1), setOf("-R", "--repo", "-t", "--title", "-n", "--notes"))
        val repo = repoArg(o)
        when (a.firstOrNull()) {
            "list" -> {
                val l = arr(Gh.api("GET", "repos/$repo/releases"), "listing releases")
                for (i in 0 until l.length()) { val r = l.getJSONObject(i); println("${r.optString("name", r.getString("tag_name"))}\t${r.getString("tag_name")}\t${r.optString("published_at")}") }
            }
            "create" -> {
                val tag = o.pos.firstOrNull() ?: throw Fail("usage: gh release create <tag> [files...] [-t title] [-n notes]")
                val b = JSONObject().put("tag_name", tag).put("name", o.v("-t", "--title") ?: tag).put("body", o.v("-n", "--notes") ?: "")
                val j = ok(Gh.api("POST", "repos/$repo/releases", b.toString()), "creating release")!!
                println(j.getString("html_url"))
                val id = j.getLong("id")
                for (f in o.pos.drop(1)) {
                    val file = Cli.res(f)
                    val up = Http.request("POST", "https://uploads.github.com/repos/$repo/releases/$id/assets?name=${file.name}",
                        Gh.authHeaders() + ("Content-Type" to "application/octet-stream"), file.readBytes())
                    if (up.code >= 400) throw Fail("gh: upload of ${file.name} failed (HTTP ${up.code})")
                    println("uploaded ${file.name}")
                }
            }
            else -> throw Fail("usage: gh release create|list")
        }
        return 0
    }

    private fun search(a: List<String>): Int {
        if (a.firstOrNull() != "repos" || a.size < 2) throw Fail("usage: gh search repos <query>")
        val q = java.net.URLEncoder.encode(a.drop(1).joinToString(" "), "UTF-8")
        val items = ok(Gh.api("GET", "search/repositories?q=$q&per_page=20"), "searching")!!.getJSONArray("items")
        for (i in 0 until items.length()) { val r = items.getJSONObject(i); println("${r.getString("full_name")}\t${r.optInt("stargazers_count")}\t${r.optString("description", "")}") }
        return 0
    }

    // ---------- api ----------

    private fun api(a: List<String>): Int {
        val o = Opts(a, setOf("-X", "--method", "-f", "--raw-field", "-F", "--field", "-q", "--jq", "--input", "-H", "--header"))
        val ep = o.pos.firstOrNull() ?: throw Fail("usage: gh api <endpoint> [-X METHOD] [-f key=value] [-q .path]")
        val fields = o.all("-f", "--raw-field", "-F", "--field")
        var method = o.v("-X", "--method") ?: if (fields.isNotEmpty() || o.v("--input") != null) "POST" else "GET"
        var path = ep
        var body: String? = null
        if (fields.isNotEmpty()) {
            if (method == "GET") path += (if (path.contains('?')) "&" else "?") + fields.joinToString("&") { it }
            else { val j = JSONObject(); fields.forEach { j.put(it.substringBefore('='), it.substringAfter('=', "")) }; body = j.toString() }
        }
        if (o.v("--input") == "-") body = generateSequence(::readLine).joinToString("\n")
        val r = Gh.api(method, path, body)
        if (r.code >= 400) { System.err.println("gh: HTTP ${r.code}"); System.err.println(r.body); return 1 }
        val q = o.v("-q", "--jq")
        val text = r.body.trim()
        if (text.isEmpty()) return 0
        val parsed: Any = try { if (text.startsWith("[")) JSONArray(text) else if (text.startsWith("{")) JSONObject(text) else text } catch (e: Exception) { text }
        if (q != null) { println(Jq.eval(parsed, q)); return 0 }
        println(when (parsed) { is JSONObject -> parsed.toString(2); is JSONArray -> parsed.toString(2); else -> parsed.toString() })
        return 0
    }
}

/** Minimal jq: supports .a.b[0].c paths only. */
object Jq {
    fun eval(root: Any, expr: String): String {
        var cur: Any? = root
        val tokens = Regex("\\.([A-Za-z0-9_\\-]+)|\\[(\\d+)\\]").findAll(expr)
        for (t in tokens) {
            cur = when {
                t.groupValues[1].isNotEmpty() -> (cur as? JSONObject)?.opt(t.groupValues[1])
                else -> (cur as? JSONArray)?.opt(t.groupValues[2].toInt())
            }
            if (cur == null) return "null"
        }
        return when (cur) { is JSONObject -> cur.toString(2); is JSONArray -> cur.toString(2); else -> cur.toString() }
    }
}
