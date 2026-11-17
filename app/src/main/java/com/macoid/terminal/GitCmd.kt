package com.macoid.terminal

import org.eclipse.jgit.api.CreateBranchCommand
import org.eclipse.jgit.api.Git
import org.eclipse.jgit.api.ListBranchCommand
import org.eclipse.jgit.api.MergeCommand
import org.eclipse.jgit.api.MergeResult
import org.eclipse.jgit.api.RebaseCommand
import org.eclipse.jgit.api.ResetCommand
import org.eclipse.jgit.api.errors.GitAPIException
import org.eclipse.jgit.diff.DiffFormatter
import org.eclipse.jgit.lib.BranchTrackingStatus
import org.eclipse.jgit.lib.ObjectId
import org.eclipse.jgit.lib.Repository
import org.eclipse.jgit.lib.StoredConfig
import org.eclipse.jgit.lib.TextProgressMonitor
import org.eclipse.jgit.revwalk.RevCommit
import org.eclipse.jgit.revwalk.RevWalk
import org.eclipse.jgit.storage.file.FileBasedConfig
import org.eclipse.jgit.storage.file.FileRepositoryBuilder
import org.eclipse.jgit.transport.CredentialsProvider
import org.eclipse.jgit.transport.RefSpec
import org.eclipse.jgit.transport.RemoteRefUpdate
import org.eclipse.jgit.transport.TagOpt
import org.eclipse.jgit.transport.URIish
import org.eclipse.jgit.transport.UsernamePasswordCredentialsProvider
import org.eclipse.jgit.treewalk.AbstractTreeIterator
import org.eclipse.jgit.treewalk.CanonicalTreeParser
import org.eclipse.jgit.treewalk.EmptyTreeIterator
import org.eclipse.jgit.util.FS
import java.io.File
import java.io.PrintWriter
import java.text.SimpleDateFormat
import java.util.Locale

/** A real git for Android, built on JGit. */
object GitCmd {
    class Fail(msg: String) : Exception(msg)

    private var cwd: File = Cli.cwd()
    private val home: File get() = File(System.getProperty("user.home") ?: ".")

    fun run(argsIn: List<String>): Int {
        var a = argsIn
        while (a.size >= 2 && a[0] == "-C") { cwd = File(cwd, a[1]).canonicalFile; a = a.drop(2) }
        val cmd = a.firstOrNull() ?: return help()
        val rest = a.drop(1)
        return try {
            dispatch(cmd, rest)
        } catch (e: Fail) {
            System.err.println(e.message); 128
        } catch (e: GitAPIException) {
            System.err.println("fatal: ${e.message}")
            if ((e.message ?: "").contains("not authorized", true) || (e.message ?: "").contains("Authentication", true))
                System.err.println("hint: run 'gh auth login' with a token that has 'repo' access.")
            128
        }
    }

    private fun help(): Int {
        println("usage: git [-C <path>] <command> [<args>]\n")
        println("commands: init clone status add rm mv commit log show diff branch checkout switch restore")
        println("          merge rebase pull fetch push remote tag reset stash cherry-pick revert clean")
        println("          blame ls-files rev-parse config grep version")
        return 1
    }

    private fun dispatch(cmd: String, a: List<String>): Int = when (cmd) {
        "version", "--version", "-v" -> { println("git version 2.43.0 (Macoid / JGit)"); 0 }
        "help", "--help", "-h" -> help()
        "init" -> init(a)
        "clone" -> clone(a)
        "status" -> status(a)
        "add" -> add(a)
        "rm" -> rm(a)
        "mv" -> mv(a)
        "commit" -> commit(a)
        "log" -> log(a)
        "show" -> show(a)
        "diff" -> diff(a)
        "branch" -> branch(a)
        "checkout" -> checkout(a, false)
        "switch" -> checkout(a, true)
        "restore" -> restore(a)
        "merge" -> merge(a)
        "rebase" -> rebase(a)
        "pull" -> pull(a)
        "fetch" -> fetch(a)
        "push" -> push(a)
        "remote" -> remote(a)
        "tag" -> tag(a)
        "reset" -> reset(a)
        "stash" -> stash(a)
        "cherry-pick" -> { val r = repo(); val res = Git(r).cherryPick().include(resolve(r, a.last())).call(); println(res.status); if (res.status.name == "OK") 0 else 1 }
        "revert" -> { val r = repo(); Git(r).revert().include(resolve(r, a.last())).call(); 0 }
        "clean" -> clean(a)
        "blame" -> blame(a)
        "ls-files" -> { val r = repo(); val dc = r.readDirCache(); for (i in 0 until dc.entryCount) println(dc.getEntry(i).pathString); 0 }
        "rev-parse" -> revParse(a)
        "config" -> configCmd(a)
        "grep" -> grep(a)
        else -> { System.err.println("git: '$cmd' is not a git command. See 'git help'."); 1 }
    }

    // ---------- helpers ----------

    private fun repoOrNull(): Repository? {
        val b = FileRepositoryBuilder().readEnvironment().findGitDir(cwd)
        return if (b.gitDir == null) null else b.build()
    }

    private fun repo(): Repository =
        repoOrNull() ?: throw Fail("fatal: not a git repository (or any of the parent directories): .git")

    private fun resolve(r: Repository, rev: String): ObjectId =
        r.resolve(rev) ?: throw Fail("fatal: bad revision '$rev'")

    private fun creds(url: String?): CredentialsProvider? {
        val host = try { URIish(url ?: "").host } catch (e: Exception) { null } ?: return null
        val gh = Gh.token()
        if (gh != null && (host == "github.com" || host.endsWith(".github.com") || host.endsWith("githubusercontent.com")))
            return UsernamePasswordCredentialsProvider(gh, "")
        val t = System.getenv("GIT_TOKEN") ?: return null
        return UsernamePasswordCredentialsProvider(System.getenv("GIT_USER") ?: "oauth2", t)
    }

    private fun expandUrl(u: String): String =
        if (!u.contains("://") && !u.contains("@") && Regex("^[\\w.-]+/[\\w.-]+$").matches(u) && !File(cwd, u).exists())
            "https://github.com/$u.git" else u

    private fun repoPath(r: Repository, p: String): String {
        val wt = r.workTree.canonicalFile
        val f = File(if (File(p).isAbsolute) p else File(cwd, p).path).canonicalFile
        val rel = f.relativeTo(wt).path
        return if (rel.isEmpty()) "." else rel.replace(File.separatorChar, '/')
    }

    private fun fmtDate(c: RevCommit): String {
        val id = c.authorIdent
        val f = SimpleDateFormat("EEE MMM d HH:mm:ss yyyy Z", Locale.ENGLISH)
        f.timeZone = id.timeZone
        return f.format(id.getWhen())
    }

    private fun progress() = TextProgressMonitor(PrintWriter(System.err, true))

    private fun tree(r: Repository, rev: String): AbstractTreeIterator {
        val id = r.resolve("$rev^{tree}") ?: throw Fail("fatal: bad revision '$rev'")
        val p = CanonicalTreeParser()
        r.newObjectReader().use { p.reset(it, id) }
        return p
    }

    // ---------- commands ----------

    private fun init(a: List<String>): Int {
        val dir = File(cwd, a.firstOrNull { !it.startsWith("-") } ?: ".").canonicalFile
        Git.init().setDirectory(dir).setInitialBranch("main").call().close()
        println("Initialized empty Git repository in ${dir.path}/.git/")
        return 0
    }

    private fun clone(a: List<String>): Int {
        val o = Opts(a, setOf("--depth", "-b", "--branch"))
        val url = expandUrl(o.pos.firstOrNull() ?: throw Fail("fatal: You must specify a repository to clone."))
        val name = o.pos.getOrNull(1) ?: url.trimEnd('/').substringAfterLast('/').removeSuffix(".git")
        val dir = File(cwd, name)
        println("Cloning into '$name'...")
        val c = Git.cloneRepository().setURI(url).setDirectory(dir).setProgressMonitor(progress())
        creds(url)?.let { c.setCredentialsProvider(it) }
        o.v("--depth")?.toIntOrNull()?.let { c.setDepth(it) }
        o.v("-b", "--branch")?.let { c.setBranch(it) }
        if (o.has("--bare")) c.setBare(true)
        c.call().close()
        return 0
    }

    private fun status(a: List<String>): Int {
        val r = repo()
        val st = Git(r).status().call()
        if (a.any { it == "-s" || it == "--short" || it == "--porcelain" }) {
            val x = HashMap<String, Char>(); val y = HashMap<String, Char>()
            st.added.forEach { x[it] = 'A' }; st.changed.forEach { x[it] = 'M' }; st.removed.forEach { x[it] = 'D' }
            st.modified.forEach { y[it] = 'M' }; st.missing.forEach { y[it] = 'D' }
            for (p in (x.keys + y.keys).toSortedSet()) println("${x[p] ?: ' '}${y[p] ?: ' '} $p")
            st.conflicting.sorted().forEach { println("UU $it") }
            st.untracked.sorted().forEach { println("?? $it") }
            return 0
        }
        println("On branch ${r.branch}")
        try {
            val t = BranchTrackingStatus.of(r, r.branch)
            if (t != null) {
                val n = t.remoteTrackingBranch.removePrefix("refs/remotes/")
                if (t.aheadCount > 0 && t.behindCount > 0) println("Your branch and '$n' have diverged (${t.aheadCount} ahead, ${t.behindCount} behind).")
                else if (t.aheadCount > 0) println("Your branch is ahead of '$n' by ${t.aheadCount} commit(s).")
                else if (t.behindCount > 0) println("Your branch is behind '$n' by ${t.behindCount} commit(s).")
                else println("Your branch is up to date with '$n'.")
            }
        } catch (e: Exception) { /* no tracking info */ }
        if (st.conflicting.isNotEmpty()) { println("\nUnmerged paths:"); st.conflicting.sorted().forEach { println("\tboth modified:   $it") } }
        if (st.added.isNotEmpty() || st.changed.isNotEmpty() || st.removed.isNotEmpty()) {
            println("\nChanges to be committed:")
            st.added.sorted().forEach { println("\tnew file:   $it") }
            st.changed.sorted().forEach { println("\tmodified:   $it") }
            st.removed.sorted().forEach { println("\tdeleted:    $it") }
        }
        if (st.modified.isNotEmpty() || st.missing.isNotEmpty()) {
            println("\nChanges not staged for commit:")
            st.modified.sorted().forEach { println("\tmodified:   $it") }
            st.missing.sorted().forEach { println("\tdeleted:    $it") }
        }
        if (st.untracked.isNotEmpty()) { println("\nUntracked files:"); st.untracked.sorted().forEach { println("\t$it") } }
        if (st.isClean) println("nothing to commit, working tree clean")
        return 0
    }

    private fun add(a: List<String>): Int {
        val r = repo(); val g = Git(r)
        val paths = a.filter { !it.startsWith("-") }
        val all = a.contains("-A") || a.contains("--all") || paths.isEmpty() && false
        if (paths.isEmpty() && !all) throw Fail("Nothing specified, nothing added.")
        val targets = if (all && paths.isEmpty()) listOf(".") else paths.map { repoPath(r, it) }
        val c = g.add(); targets.forEach { c.addFilepattern(it) }; c.call()
        val u = g.add().setUpdate(true); targets.forEach { u.addFilepattern(it) }; u.call()
        return 0
    }

    private fun rm(a: List<String>): Int {
        val r = repo()
        val c = Git(r).rm().setCached(a.contains("--cached"))
        a.filter { !it.startsWith("-") }.forEach { c.addFilepattern(repoPath(r, it)) }
        c.call(); return 0
    }

    private fun mv(a: List<String>): Int {
        val r = repo(); val p = a.filter { !it.startsWith("-") }
        if (p.size != 2) throw Fail("usage: git mv <source> <destination>")
        val src = File(cwd, p[0]); val dst = File(cwd, p[1]).let { if (it.isDirectory) File(it, src.name) else it }
        dst.parentFile?.mkdirs()
        if (!src.renameTo(dst)) throw Fail("fatal: renaming '${p[0]}' failed")
        val g = Git(r)
        g.rm().setCached(true).addFilepattern(repoPath(r, src.path)).call()
        g.add().addFilepattern(repoPath(r, dst.path)).call()
        return 0
    }

    private fun commit(a: List<String>): Int {
        val r = repo(); val g = Git(r)
        val msgs = ArrayList<String>(); var all = false; var amend = false; var empty = false
        var i = 0
        while (i < a.size) {
            when (val x = a[i]) {
                "-m", "--message" -> { i++; msgs.add(a.getOrNull(i) ?: throw Fail("error: switch 'm' requires a value")) }
                "-am" -> { all = true; i++; msgs.add(a.getOrNull(i) ?: throw Fail("error: switch 'm' requires a value")) }
                "-a", "--all" -> all = true
                "--amend" -> amend = true
                "--allow-empty" -> empty = true
                else -> if (x.startsWith("--message=")) msgs.add(x.substringAfter('='))
            }
            i++
        }
        if (msgs.isEmpty() && !amend) throw Fail("Aborting commit due to empty commit message.\nUse: git commit -m \"message\"")
        val cfg = r.config
        if (cfg.getString("user", null, "name").isNullOrBlank() || cfg.getString("user", null, "email").isNullOrBlank())
            throw Fail("*** Please tell me who you are.\n\nRun\n\n  git config --global user.name \"Your Name\"\n  git config --global user.email \"you@example.com\"\n")
        if (!amend && !empty && r.repositoryState.name == "SAFE") {
            val st = g.status().call()
            val staged = st.added.isNotEmpty() || st.changed.isNotEmpty() || st.removed.isNotEmpty()
            val unstaged = st.modified.isNotEmpty() || st.missing.isNotEmpty()
            if (!staged && !(all && unstaged)) { println("nothing to commit, working tree clean"); return 1 }
        }
        val cmd = g.commit().setAll(all).setAmend(amend).setAllowEmpty(true)
        if (msgs.isNotEmpty()) cmd.setMessage(msgs.joinToString("\n\n"))
        val c = cmd.call()
        println("[${r.branch} ${c.abbreviate(7).name()}] ${c.shortMessage}")
        return 0
    }

    private fun log(a: List<String>): Int {
        val r = repo(); val g = Git(r)
        var oneline = false; var max = -1; var all = false; var rev: String? = null
        val paths = ArrayList<String>()
        var i = 0
        while (i < a.size) {
            val x = a[i]
            when {
                x == "--oneline" -> oneline = true
                x == "--all" -> all = true
                x == "-n" -> { i++; max = a.getOrNull(i)?.toIntOrNull() ?: -1 }
                x.startsWith("--max-count=") -> max = x.substringAfter('=').toIntOrNull() ?: -1
                Regex("^-\\d+$").matches(x) -> max = x.substring(1).toInt()
                x == "--" -> { paths.addAll(a.drop(i + 1)); i = a.size }
                x.startsWith("-") -> {}
                rev == null && r.resolve(x) != null -> rev = x
                else -> paths.add(x)
            }
            i++
        }
        val head = r.resolve(rev ?: "HEAD") ?: throw Fail("fatal: your current branch '${r.branch}' does not have any commits yet")
        val lc = g.log().add(head)
        if (all) lc.all()
        paths.forEach { lc.addPath(repoPath(r, it)) }
        if (max > 0) lc.setMaxCount(max)
        for (c in lc.call()) {
            if (oneline) println("${c.abbreviate(7).name()} ${c.shortMessage}")
            else {
                println("commit ${c.name}")
                println("Author: ${c.authorIdent.name} <${c.authorIdent.emailAddress}>")
                println("Date:   ${fmtDate(c)}\n")
                c.fullMessage.trimEnd().lines().forEach { println("    $it") }
                println()
            }
        }
        return 0
    }

    private fun show(a: List<String>): Int {
        val r = repo()
        val rev = a.firstOrNull { !it.startsWith("-") } ?: "HEAD"
        val id = resolve(r, rev)
        RevWalk(r).use { w ->
            val c = w.parseCommit(id)
            println("commit ${c.name}")
            println("Author: ${c.authorIdent.name} <${c.authorIdent.emailAddress}>")
            println("Date:   ${fmtDate(c)}\n")
            c.fullMessage.trimEnd().lines().forEach { println("    $it") }
            println()
            val oldT: AbstractTreeIterator = if (c.parentCount > 0) tree(r, c.getParent(0).name) else EmptyTreeIterator()
            DiffFormatter(System.out).use { df ->
                df.setRepository(r); df.isDetectRenames = true
                df.format(df.scan(oldT, tree(r, c.name)))
                df.flush()
            }
        }
        return 0
    }

    private fun diff(a: List<String>): Int {
        val r = repo(); val g = Git(r)
        val staged = a.contains("--cached") || a.contains("--staged")
        val revs = a.filter { !it.startsWith("-") && r.resolve(it) != null }
        val c = g.diff().setOutputStream(System.out)
        if (revs.size >= 2) c.setOldTree(tree(r, revs[0])).setNewTree(tree(r, revs[1]))
        else if (revs.size == 1) c.setOldTree(tree(r, revs[0])).setNewTree(tree(r, "HEAD"))
        else c.setCached(staged)
        c.call(); System.out.flush(); return 0
    }

    private fun branch(a: List<String>): Int {
        val r = repo(); val g = Git(r)
        val pos = a.filter { !it.startsWith("-") }
        fun delete(force: Boolean) { g.branchDelete().setBranchNames(*pos.toTypedArray()).setForce(force).call().forEach { println("Deleted branch ${Repository.shortenRefName(it)}") } }
        when {
            a.contains("-d") -> delete(false)
            a.contains("-D") -> delete(true)
            a.contains("-m") || a.contains("-M") -> {
                val (o, n) = if (pos.size >= 2) pos[0] to pos[1] else r.branch to pos[0]
                g.branchRename().setOldName(o).setNewName(n).call()
            }
            pos.isNotEmpty() -> {
                val c = g.branchCreate().setName(pos[0])
                if (pos.size > 1) c.setStartPoint(pos[1])
                c.call()
            }
            else -> {
                val mode = if (a.contains("-a")) ListBranchCommand.ListMode.ALL else if (a.contains("-r")) null else ListBranchCommand.ListMode.ALL
                val lc = g.branchList()
                if (a.contains("-r")) lc.setListMode(ListBranchCommand.ListMode.REMOTE)
                else if (a.contains("-a")) lc.setListMode(mode)
                val cur = r.fullBranch
                lc.call().sortedBy { it.name }.forEach {
                    println("${if (it.name == cur) "* " else "  "}${Repository.shortenRefName(it.name)}")
                }
            }
        }
        return 0
    }

    private fun checkout(a: List<String>, isSwitch: Boolean): Int {
        val r = repo(); val g = Git(r)
        val newBranch = a.indexOfFirst { it == "-b" || it == "-B" || it == "-c" || it == "-C" }
        val pos = a.filterIndexed { idx, s -> !s.startsWith("-") && !(newBranch >= 0 && idx == newBranch + 1 && false) }
        if (newBranch >= 0) {
            val name = a.getOrNull(newBranch + 1) ?: throw Fail("fatal: switch requires a branch name")
            val start = a.drop(newBranch + 2).firstOrNull { !it.startsWith("-") }
            val c = g.checkout().setCreateBranch(true).setName(name).setForced(a.contains("-B") || a.contains("-C"))
            if (start != null) c.setStartPoint(start)
            c.call(); println("Switched to a new branch '$name'"); return 0
        }
        val target = pos.firstOrNull() ?: throw Fail("fatal: missing branch or path")
        val dashdash = a.indexOf("--")
        val isRef = !isSwitch && dashdash < 0 && (r.findRef(target) != null || r.resolve(target) != null) || isSwitch
        if (isRef && dashdash < 0) {
            val hasLocal = r.findRef("refs/heads/$target") != null
            val remote = r.findRef("refs/remotes/origin/$target")
            if (!hasLocal && remote != null) {
                g.checkout().setCreateBranch(true).setName(target).setStartPoint("origin/$target")
                    .setUpstreamMode(CreateBranchCommand.SetupUpstreamMode.TRACK).call()
                println("branch '$target' set up to track 'origin/$target'.")
            } else {
                g.checkout().setName(target).call()
                println("Switched to ${if (hasLocal) "branch '$target'" else "'$target' (detached HEAD)"}")
            }
            return 0
        }
        val files = if (dashdash >= 0) a.drop(dashdash + 1) else pos
        val c = g.checkout(); files.forEach { c.addPath(repoPath(r, it)) }; c.call()
        return 0
    }

    private fun restore(a: List<String>): Int {
        val r = repo(); val g = Git(r)
        val files = a.filter { !it.startsWith("-") }.map { repoPath(r, it) }
        if (a.contains("--staged")) { val c = g.reset(); files.forEach { c.addPath(it) }; c.call() }
        else { val c = g.checkout(); files.forEach { c.addPath(it) }; c.call() }
        return 0
    }

    private fun merge(a: List<String>): Int {
        val r = repo(); val g = Git(r)
        if (a.contains("--abort")) { g.reset().setMode(ResetCommand.ResetType.HARD).call(); println("Merge aborted."); return 0 }
        val o = Opts(a, setOf("-m"))
        val name = o.pos.firstOrNull() ?: throw Fail("fatal: No commit specified.")
        val id = resolve(r, name)
        val c = g.merge().include(name, id)
        if (o.has("--no-ff")) c.setFastForward(MergeCommand.FastForwardMode.NO_FF)
        if (o.has("--ff-only")) c.setFastForward(MergeCommand.FastForwardMode.FF_ONLY)
        if (o.has("--squash")) c.setSquash(true)
        o.v("-m")?.let { c.setMessage(it) }
        val res = c.call()
        return when (res.mergeStatus) {
            MergeResult.MergeStatus.ALREADY_UP_TO_DATE -> { println("Already up to date."); 0 }
            MergeResult.MergeStatus.FAST_FORWARD, MergeResult.MergeStatus.FAST_FORWARD_SQUASHED -> { println("Fast-forward"); 0 }
            MergeResult.MergeStatus.CONFLICTING -> {
                res.conflicts?.keys?.forEach { println("CONFLICT (content): Merge conflict in $it") }
                println("Automatic merge failed; fix conflicts and then commit the result."); 1
            }
            else -> { println("Merge: ${res.mergeStatus}"); if (res.mergeStatus.isSuccessful) 0 else 1 }
        }
    }

    private fun rebase(a: List<String>): Int {
        val g = Git(repo())
        val c = g.rebase()
        when {
            a.contains("--continue") -> c.setOperation(RebaseCommand.Operation.CONTINUE)
            a.contains("--abort") -> c.setOperation(RebaseCommand.Operation.ABORT)
            a.contains("--skip") -> c.setOperation(RebaseCommand.Operation.SKIP)
            else -> c.setUpstream(a.firstOrNull { !it.startsWith("-") } ?: throw Fail("fatal: no upstream given"))
        }
        val res = c.call(); println(res.status)
        return if (res.status.isSuccessful) 0 else 1
    }

    private fun remoteUrl(r: Repository, name: String): String? = r.config.getString("remote", name, "url")

    private fun pull(a: List<String>): Int {
        val r = repo(); val g = Git(r)
        val remote = r.config.getString("branch", r.branch, "remote") ?: "origin"
        val c = g.pull().setProgressMonitor(progress()).setRebase(a.contains("--rebase"))
        creds(remoteUrl(r, remote))?.let { c.setCredentialsProvider(it) }
        val res = c.call()
        if (res.mergeResult?.mergeStatus == MergeResult.MergeStatus.ALREADY_UP_TO_DATE) println("Already up to date.")
        else println(res.mergeResult?.mergeStatus ?: res.rebaseResult?.status ?: "done")
        return if (res.isSuccessful) 0 else 1
    }

    private fun fetch(a: List<String>): Int {
        val r = repo(); val g = Git(r)
        val remote = a.firstOrNull { !it.startsWith("-") } ?: "origin"
        val c = g.fetch().setRemote(remote).setProgressMonitor(progress()).setRemoveDeletedRefs(a.contains("--prune") || a.contains("-p"))
        if (a.contains("--tags")) c.setTagOpt(TagOpt.FETCH_TAGS)
        creds(remoteUrl(r, remote))?.let { c.setCredentialsProvider(it) }
        val res = c.call()
        res.trackingRefUpdates.forEach { println(" ${it.result}  ${it.remoteName} -> ${Repository.shortenRefName(it.localName)}") }
        return 0
    }

    private fun push(a: List<String>): Int {
        val r = repo(); val g = Git(r)
        val pos = a.filter { !it.startsWith("-") }
        val remote = pos.firstOrNull() ?: r.config.getString("branch", r.branch, "remote") ?: "origin"
        val specs = pos.drop(1).map {
            when {
                it.contains(":") -> it
                it == "HEAD" -> "refs/heads/${r.branch}:refs/heads/${r.branch}"
                else -> "refs/heads/$it:refs/heads/$it"
            }
        }.toMutableList()
        if (a.contains("--delete") || a.contains("-d")) { specs.replaceAll { ":" + it.substringAfter(':') } }
        if (specs.isEmpty() && !a.contains("--tags")) specs.add("refs/heads/${r.branch}:refs/heads/${r.branch}")
        val c = g.push().setRemote(remote).setProgressMonitor(progress()).setForce(a.contains("-f") || a.contains("--force"))
        if (specs.isNotEmpty()) c.setRefSpecs(specs.map { RefSpec(it) })
        if (a.contains("--tags")) c.setPushTags()
        creds(remoteUrl(r, remote) ?: remote)?.let { c.setCredentialsProvider(it) }
        var rc = 0
        for (pr in c.call()) {
            println("To ${pr.uri}")
            pr.messages?.takeIf { it.isNotBlank() }?.lines()?.forEach { System.err.println("remote: $it") }
            for (u in pr.remoteUpdates) {
                val ok = u.status == RemoteRefUpdate.Status.OK || u.status == RemoteRefUpdate.Status.UP_TO_DATE
                if (!ok) rc = 1
                println(" ${if (ok) "*" else "!"} ${Repository.shortenRefName(u.remoteName)}  [${u.status}] ${u.message ?: ""}")
            }
        }
        if (rc == 0 && (a.contains("-u") || a.contains("--set-upstream"))) {
            val b = r.branch
            val cfg = r.config
            cfg.setString("branch", b, "remote", remote); cfg.setString("branch", b, "merge", "refs/heads/$b"); cfg.save()
            println("branch '$b' set up to track '$remote/$b'.")
        }
        return rc
    }

    private fun remote(a: List<String>): Int {
        val r = repo(); val c = r.config
        when (a.firstOrNull()) {
            null, "-v" -> c.getSubsections("remote").sorted().forEach {
                if (a.isEmpty()) println(it) else { val u = c.getString("remote", it, "url"); println("$it\t$u (fetch)\n$it\t$u (push)") }
            }
            "add" -> {
                if (a.size < 3) throw Fail("usage: git remote add <name> <url>")
                c.setString("remote", a[1], "url", expandUrl(a[2]))
                c.setString("remote", a[1], "fetch", "+refs/heads/*:refs/remotes/${a[1]}/*"); c.save()
            }
            "remove", "rm" -> { c.unsetSection("remote", a[1]); c.save() }
            "set-url" -> { c.setString("remote", a[1], "url", expandUrl(a[2])); c.save() }
            "get-url" -> println(c.getString("remote", a[1], "url") ?: "")
            else -> throw Fail("usage: git remote [-v] | add | remove | set-url | get-url")
        }
        return 0
    }

    private fun tag(a: List<String>): Int {
        val r = repo(); val g = Git(r)
        val o = Opts(a, setOf("-m"))
        when {
            o.has("-d") -> { g.tagDelete().setTags(*o.pos.toTypedArray()).call(); println("Deleted tag(s): ${o.pos.joinToString()}") }
            o.pos.isEmpty() -> g.tagList().call().map { Repository.shortenRefName(it.name) }.sorted().forEach { println(it) }
            else -> {
                val c = g.tag().setName(o.pos[0]).setSigned(false)
                val m = o.v("-m")
                c.setAnnotated(m != null || o.has("-a")).setMessage(m ?: o.pos[0])
                if (o.pos.size > 1) c.setObjectId(RevWalk(r).use { it.parseCommit(resolve(r, o.pos[1])) })
                c.call()
            }
        }
        return 0
    }

    private fun reset(a: List<String>): Int {
        val r = repo(); val g = Git(r)
        val mode = when {
            a.contains("--hard") -> ResetCommand.ResetType.HARD
            a.contains("--soft") -> ResetCommand.ResetType.SOFT
            else -> ResetCommand.ResetType.MIXED
        }
        val pos = a.filter { !it.startsWith("-") }
        if (pos.isNotEmpty() && r.resolve(pos[0]) == null) {
            val c = g.reset(); pos.forEach { c.addPath(repoPath(r, it)) }; c.call(); return 0
        }
        val c = g.reset().setMode(mode)
        pos.firstOrNull()?.let { c.setRef(it) }
        val head = c.call()
        println("HEAD is now at ${head.name.substring(0, 7)}")
        return 0
    }

    private fun stash(a: List<String>): Int {
        val g = Git(repo())
        when (a.firstOrNull() ?: "push") {
            "push", "save" -> {
                val m = a.indexOf("-m").let { if (it >= 0) a.getOrNull(it + 1) else null }
                val s = g.stashCreate().setIncludeUntracked(a.contains("-u") || a.contains("--include-untracked"))
                m?.let { s.setWorkingDirectoryMessage(it) }
                println(if (s.call() == null) "No local changes to save" else "Saved working directory and index state")
            }
            "pop" -> { g.stashApply().call(); g.stashDrop().setStashRef(0).call(); println("Dropped stash@{0}") }
            "apply" -> g.stashApply().call()
            "list" -> g.stashList().call().forEachIndexed { i, c -> println("stash@{$i}: ${c.shortMessage}") }
            "drop" -> g.stashDrop().setStashRef(0).call()
            "clear" -> { while (g.stashList().call().isNotEmpty()) g.stashDrop().setStashRef(0).call() }
            else -> throw Fail("usage: git stash [push|pop|apply|list|drop|clear]")
        }
        return 0
    }

    private fun clean(a: List<String>): Int {
        val g = Git(repo())
        val dry = a.contains("-n") || a.contains("--dry-run")
        if (!dry && !a.any { it.startsWith("-") && it.contains('f') }) throw Fail("fatal: clean requires -f (or -n for a dry run)")
        val res = g.clean().setCleanDirectories(a.any { it.startsWith("-") && it.contains('d') }).setDryRun(dry).call()
        res.sorted().forEach { println("${if (dry) "Would remove" else "Removing"} $it") }
        return 0
    }

    private fun blame(a: List<String>): Int {
        val r = repo()
        val p = repoPath(r, a.firstOrNull { !it.startsWith("-") } ?: throw Fail("usage: git blame <file>"))
        val res = Git(r).blame().setFilePath(p).setStartCommit(resolve(r, "HEAD")).call() ?: throw Fail("fatal: no such path '$p'")
        for (i in 0 until res.resultContents.size()) {
            val c = res.getSourceCommit(i)
            println("${c.name.substring(0, 8)} (${res.getSourceAuthor(i).name}) ${i + 1}) ${res.resultContents.getString(i)}")
        }
        return 0
    }

    private fun revParse(a: List<String>): Int {
        val r = repo()
        when {
            a.contains("--show-toplevel") -> println(r.workTree.path)
            a.contains("--git-dir") -> println(r.directory.path)
            a.contains("--is-inside-work-tree") -> println("true")
            a.contains("--abbrev-ref") -> println(r.branch)
            else -> {
                val rev = a.firstOrNull { !it.startsWith("-") } ?: "HEAD"
                val id = resolve(r, rev)
                println(if (a.contains("--short")) id.name.substring(0, 7) else id.name)
            }
        }
        return 0
    }

    private fun configCmd(a: List<String>): Int {
        var scope: String? = null; var list = false; var unset = false
        val rest = ArrayList<String>()
        for (x in a) when (x) {
            "--global" -> scope = "global"; "--local" -> scope = "local"
            "--list", "-l" -> list = true; "--unset" -> unset = true; "--get" -> {}
            else -> rest.add(x)
        }
        val global = FileBasedConfig(File(home, ".gitconfig"), FS.DETECTED).also { it.load() }
        val repo = repoOrNull()
        val readCfg: StoredConfig = when (scope) { "global" -> global; "local" -> (repo ?: throw Fail("fatal: not in a git directory")).config; else -> repo?.config ?: global }
        val writeCfg: StoredConfig = when (scope) { "global" -> global; else -> repo?.config ?: global }
        if (list) {
            for (s in readCfg.sections) {
                readCfg.getNames(s).forEach { println("$s.$it=${readCfg.getString(s, null, it)}") }
                readCfg.getSubsections(s).forEach { sub -> readCfg.getNames(s, sub).forEach { println("$s.$sub.$it=${readCfg.getString(s, sub, it)}") } }
            }
            return 0
        }
        val key = rest.firstOrNull() ?: throw Fail("usage: git config [--global] <key> [<value>]")
        val parts = key.split('.')
        if (parts.size < 2) throw Fail("error: key does not contain a section: $key")
        val section = parts.first(); val name = parts.last()
        val sub = if (parts.size > 2) parts.subList(1, parts.size - 1).joinToString(".") else null
        if (unset) { writeCfg.unset(section, sub, name); writeCfg.save(); return 0 }
        if (rest.size >= 2) { writeCfg.setString(section, sub, name, rest[1]); writeCfg.save(); return 0 }
        val v = readCfg.getString(section, sub, name) ?: return 1
        println(v); return 0
    }

    private fun grep(a: List<String>): Int {
        val r = repo()
        val pb = ProcessBuilder(listOf("/system/bin/grep", "-rnI", "--exclude-dir=.git") + a + listOf(r.workTree.path))
        pb.inheritIO()
        return pb.start().waitFor()
    }
}
