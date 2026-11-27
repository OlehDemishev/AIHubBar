import Foundation

// The rules of level 1, ported from `desktop/skill-scanner/src/rules.rs` (2026-11-26, rules v2): the same ids, severities
// and patterns, so both versions give the same verdicts on the shared fixtures. Patterns are ICU regular expressions
// (`NSRegularExpression`); the Rust crate's syntax used here means the same in both.

enum SkillSeverity: Int, Comparable, Codable, Sendable, CaseIterable {
    case info, low, medium, high, critical

    static func < (a: SkillSeverity, b: SkillSeverity) -> Bool { a.rawValue < b.rawValue }

    var lowered: SkillSeverity { SkillSeverity(rawValue: max(0, rawValue - 1)) ?? .info }

    var weight: Int {
        switch self {
        case .info: 0
        case .low: 5
        case .medium: 15
        case .high: 35
        case .critical: 80
        }
    }

    var name: String { ["info", "low", "medium", "high", "critical"][rawValue] }

    init?(name: String) {
        guard let index = ["info", "low", "medium", "high", "critical"].firstIndex(of: name) else { return nil }
        self.init(rawValue: index)
    }
}

/// What a rule is about; the interface groups findings by it.
enum SkillCategory: String, Codable, Sendable, CaseIterable {
    case scripts, network, execution, secrets, system, dependencies, obfuscation, injection, plugin, metadata
}

struct LineRule: Sendable {
    /// In a document (SKILL.md, references) most patterns are a mention or an example, not code that runs by itself.
    enum InDocs: Sendable {
        /// As serious in a document as in code: the agent may follow it.
        case same
        /// One step lower.
        case lower
        /// Not looked for in documents.
        case skip
    }

    var id: String
    var severity: SkillSeverity
    var inDocs: InDocs
    var pattern: String
}

enum SkillRules {
    /// Credential files and stores. `.pub` keys and `known_hosts` are not secrets and are filtered out after the match.
    static let secretFiles = ##"(?:~|\$HOME|\$\{HOME\}|%USERPROFILE%|\$env:USERPROFILE|/Users/[^/\s]+|/home/[^/\s]+|expanduser\([^)]*)?[/\\]?\.ssh\b|\bid_(?:rsa|ed25519|ecdsa|dsa)\b|\.aws[/\\](?:credentials|config)|\.config[/\\]gcloud|application_default_credentials|\.kube[/\\]config|\.netrc\b|\.npmrc\b|\.pypirc\b|\.gnupg\b|\.docker[/\\]config\.json|\.git-credentials|\.claude[/\\]\.credentials|\.codex[/\\]auth\.json|\.gemini[/\\]oauth_creds|\.config[/\\]gh[/\\]hosts|login\.keychain|Library[/\\]Keychains|find-(?:generic|internet)-password|\bsecret-tool\b|\bkeyring\.get_password|Login Data\b|[/\\]Cookies\b|cookies\.sqlite|logins\.json|key4\.db|Local State\b|wallet\.dat|\.(?:bash|zsh)_history|/etc/shadow|\bSAM\b.*\bSYSTEM\b|CredentialManager|Get-StoredCredential|\bcmdkey\b"##

    static let lineRules: [LineRule] = [
        LineRule(id: "net-call", severity: .medium, inDocs: .lower, pattern: ##"(?i)\b(?:curl|wget|ncat|netcat|scp|sftp|telnet)\s+\S|\bnc\s+-|\brequests\.(?:get|post|put|patch|delete|request|Session)\b|\burllib\d?\b|\bhttp\.client\b|\bhttpx\.|\baiohttp\b|\bfetch\s*\(|\baxios\b|XMLHttpRequest|\bsocket\.(?:socket|create_connection|connect)\b|\bnet\.(?:connect|createConnection|Socket)\b|Invoke-WebRequest|Invoke-RestMethod|\b(?:iwr|irm)\s+\S|Net\.WebClient|\bDownloadString\b|\bDownloadFile\b|Start-BitsTransfer|\bbitsadmin\b|\bcertutil\b.*-urlcache|\bhttp\.(?:Get|Post)\(|\breqwest\b|\bnode-fetch\b|\bgot\(|\bWebSocket\("##),
        LineRule(id: "net-upload", severity: .high, inDocs: .lower, pattern: ##"(?i)\bcurl\b[^\n]*\s(?:-d\b|--data(?:-binary|-raw|-urlencode)?\b|-F\b|--form\b|-T\b|--upload-file\b|-X\s*(?:POST|PUT)\b|--request\s+(?:POST|PUT)\b)|\bwget\b[^\n]*--post-(?:data|file)|\brequests\.(?:post|put)\b|\bhttpx\.(?:post|put)\b|\bmethod\s*[:=]\s*["'](?:POST|PUT)["']|-Method\s+(?:Post|Put)\b|\bUploadString\b|\bUploadFile\b|\burlopen\([^\n]*data\s*=|\bhttp\.Post\(|\.post\(\s*["'`]https?://"##),
        LineRule(id: "exfil-endpoint", severity: .high, inDocs: .same, pattern: ##"(?i)discord(?:app)?\.com/api/webhooks|api\.telegram\.org/bot|hooks\.slack\.com/services|pastebin\.com|paste\.ee|hastebin\.com|ghostbin\.|webhook\.site|requestbin\.|pipedream\.net|\bngrok(?:-free)?\.(?:io|app|dev)\b|transfer\.sh|\b0x0\.st\b|file\.io\b|burpcollaborator\.net|interact\.sh|\boast(?:ify)?\.(?:com|fun|live|me|online|pro|site)\b|requestcatcher\.com|beeceptor\.com|\.trycloudflare\.com|serveo\.net|localtunnel\.me"##),
        LineRule(id: "hardcoded-ip", severity: .medium, inDocs: .lower, pattern: ##"\b(?:https?|ftp|wss?|tcp)://(?:\d{1,3}\.){3}\d{1,3}\b|/dev/tcp/"##),
        LineRule(id: "pipe-to-shell", severity: .critical, inDocs: .same, pattern: ##"(?i)\b(?:curl|wget|fetch|iwr|irm|Invoke-WebRequest|Invoke-RestMethod)\b[^\n|;]*\|\s*(?:sudo\s+)?(?:(?:ba|z|da|k|fi)?sh|python\d?|node|perl|ruby|php|iex|Invoke-Expression)\b|\b(?:ba|z)?sh\s+<\(\s*(?:curl|wget)\b|\b(?:ba|z)?sh\s+-c\s+[\x22'`]\$\((?:curl|wget)\b|\b(?:iex|Invoke-Expression)\b[^\n]*(?:DownloadString|\birm\b|\biwr\b|Invoke-WebRequest|Invoke-RestMethod)|\beval\s+[\x22'`]?\$\((?:curl|wget)\b|\bsource\s+<\(\s*(?:curl|wget)\b|\bpython\d?\s+-c\s+[^\n]*urlopen[^\n]*\bexec\b|\bexec\s*\([^\n]*(?:urlopen|requests\.get)\b|\bmshta\s+https?://|\bregsvr32\b[^\n]*/i:https?://"##),
        LineRule(id: "decode-exec", severity: .critical, inDocs: .same, pattern: ##"(?i)\bbase64\s+(?:-d|-D|--decode)\b[^\n]*\|\s*(?:sudo\s+)?(?:(?:ba|z)?sh|python\d?|node|perl)\b|\b(?:eval|exec)\s*\(?[^\n]*(?:b64decode|base64\s+(?:-d|-D|--decode)|atob\s*\(|fromhex|codecs\.decode|zlib\.decompress|marshal\.loads|unhexlify)|\b(?:iex|Invoke-Expression)\b[^\n]*FromBase64String|-(?:EncodedCommand|enc|ec)\s+[A-Za-z0-9+/=]{20,}|\bnew\s+Function\s*\([^\n]*atob\s*\(|\bxxd\s+-r\b[^\n]*\|\s*(?:ba|z)?sh\b"##),
        LineRule(id: "dynamic-exec", severity: .medium, inDocs: .lower, pattern: ##"(?i)\beval\s*\(|\bexec\s*\(|\beval\s+[\x22'`$]|\b(?:ba|z)?sh\s+-c\b|\bshell\s*=\s*True\b|\bos\.(?:system|popen|exec[lv]p?e?)\s*\(|\bchild_process\b|\bexecSync\s*\(|\bnew\s+Function\s*\(|\bInvoke-Expression\b|\biex\s+[\x22'$(]|\b__import__\s*\(|\bimportlib\.import_module\s*\(|\bcompile\s*\([^\n]*[\x22']exec[\x22']|\bStart-Process\b|\bosascript\s+-e\b|\bdo shell script\b|\bpickle\.loads?\s*\(|\bvm\.runIn\w+\s*\("##),
        LineRule(id: "secret-read", severity: .critical, inDocs: .lower, pattern: ##"(?i)(?:\b(?:cat|cp|tar|zip|scp|rsync|base64|xxd|head|tail|less|more|strings|dd|open|readFile(?:Sync)?|read_text|read_bytes|ReadFile|Get-Content|gc|type|Copy-Item|Compress-Archive|shutil\.copy\w*|glob|listdir|readdir|walk)\b[^\n]{0,80}|<\s*)(?:SECRET_FILES)"##),
        LineRule(id: "sensitive-path", severity: .high, inDocs: .lower, pattern: ##"(?i)(?:SECRET_FILES)"##),
        LineRule(id: "env-dump", severity: .high, inDocs: .lower, pattern: ##"(?i)\bprintenv\b(?:\s*$|\s*[|>)])|\$\(\s*env\s*\)|`env`|(?:^|[;&|]\s*)env\s*(?:[|>]|$)|\b(?:dict|json\.dumps|str)\s*\(\s*(?:dict\s*\(\s*)?os\.environ\b|JSON\.stringify\s*\(\s*process\.env\s*[,)]|Object\.(?:entries|keys)\s*\(\s*process\.env\s*\)|Get-ChildItem\s+env:|\bgci\s+env:|\bdir\s+env:|(?:^|[;&|]\s*)set\s*>\s*\S|\bexport\s+-p\b"##),
        LineRule(id: "env-secret", severity: .medium, inDocs: .lower, pattern: ##"(?:os\.environ(?:\.get)?\s*[\[(]\s*[\x22']|os\.getenv\s*\(\s*[\x22']|process\.env\.|process\.env\[\s*[\x22']|\$env:|\$\{?|ENV\[\s*[\x22']|getenv\s*\(\s*[\x22']|std::env::var\s*\(\s*[\x22'])[A-Z0-9_]*(?:API_?KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|PRIVATE_KEY|ACCESS_KEY)[A-Z0-9_]*"##),
        LineRule(id: "dotenv-read", severity: .low, inDocs: .skip, pattern: ##"(?:^|[^A-Za-z0-9_)\]])\.env(?:\.local|\.production|\.prod)?\b"##),
        LineRule(id: "rm-rf-home", severity: .critical, inDocs: .same, pattern: ##"(?i)\brm\s+(?:-[a-z]*\s+)*-[a-z]*(?:r[a-z]*f|f[a-z]*r)[a-z]*\s+(?:--no-preserve-root\s+)?["']?(?:~/\*|\$HOME/\*|/\*|~/|\$HOME/|\$\{HOME\}/?|\$HOME|/Users|/home|/etc|/usr|/var|C:\\|/|~)["']?(?:\s|$|;|&)|\bRemove-Item\b[^\n]*-Recurse[^\n]*(?:\$HOME|\$env:USERPROFILE|C:\\(?:Users)?\s*$)|\b(?:rd|rmdir)\s+/s\s+/q\s+(?:C:\\|%USERPROFILE%)|\bshutil\.rmtree\s*\(\s*(?:os\.path\.expanduser\(\s*["']~["']\s*\)|Path\.home\(\)|["']/["'])|\bmkfs(?:\.\w+)?\s+/dev/|\bdd\s+[^\n]*\bof=/dev/(?:sd|disk|nvme|hd)|:\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:|\bdiskutil\s+erase|\bformat\s+[a-z]:\s*/"##),
        LineRule(id: "rm-rf", severity: .medium, inDocs: .lower, pattern: ##"(?i)\brm\s+(?:-[a-z]*\s+)*-[a-z]*(?:r[a-z]*f|f[a-z]*r)[a-z]*\s|\bshutil\.rmtree\s*\(|\bRemove-Item\b[^\n]*-Recurse[^\n]*-Force|\b(?:rd|rmdir)\s+/s\b|\bdel\s+/[sfq]\b|\bgit\s+clean\s+-[a-z]*f[a-z]*d|\bfs\.rm(?:Sync)?\s*\([^\n]*recursive\s*:\s*true|\bfind\b[^\n]*\s-delete\b"##),
        LineRule(id: "sudo", severity: .medium, inDocs: .lower, pattern: ##"(?i)(?:^|[\s;&|`(])sudo\s+\S|\bdoas\s+\S|\bStart-Process\b[^\n]*-Verb\s+RunAs|\brunas\s+/user|\bosascript\b[^\n]*with administrator privileges"##),
        LineRule(id: "chmod-open", severity: .medium, inDocs: .lower, pattern: ##"(?i)\bchmod\s+(?:-[a-z]+\s+)*(?:0?777|a\+rwx|ugo\+rwx|o\+w)\b|\bicacls\b[^\n]*Everyone:\(?F|\bchmod\s+[ug]\+s\b|\bxattr\s+-[a-z]*d[a-z]*\s+com\.apple\.quarantine|\bspctl\s+--master-disable|Set-MpPreference\b[^\n]*Disable|Add-MpPreference\s+-ExclusionPath|Set-ExecutionPolicy\s+(?:Bypass|Unrestricted)"##),
        LineRule(id: "persistence", severity: .high, inDocs: .lower, pattern: ##"(?i)\bLaunchAgents\b|\bLaunchDaemons\b|\blaunchctl\s+(?:load|bootstrap|enable|submit)\b|\bcrontab\b|/etc/cron|/var/spool/cron|\bsystemctl\s+(?:--user\s+)?enable\b|\.config/systemd/user|\.config/autostart|/etc/init\.d/|/etc/rc\.local|/etc/profile\.d/|CurrentVersion\\+Run(?:Once)?\b|\bschtasks\b[^\n]*/create|\bRegister-ScheduledTask\b|\bNew-ScheduledTask\w*\b|Start Menu\\+Programs\\+Startup|\bshell:startup\b|\blogin\s*item|\bLoginHook\b|\bat\s+now\s*\+"##),
        LineRule(id: "shell-rc", severity: .high, inDocs: .lower, pattern: ##"(?i)(?:>>?|\btee\b(?:\s+-a)?|\bopen\s*\(|\bappendFile(?:Sync)?\s*\(|\bwriteFile(?:Sync)?\s*\(|\bAdd-Content\b|\bSet-Content\b|\bOut-File\b|\bsed\s+-i\b|\bwrite_text\s*\()[^\n]*(?:\.bashrc|\.zshrc|\.bash_profile|\.zprofile|\.profile\b|\.zshenv|\.zlogin|config\.fish|\$PROFILE\b|Microsoft\.PowerShell_profile\.ps1|\.gitconfig|\.ssh[/\\]authorized_keys|\.ssh[/\\]config)|(?:\.bashrc|\.zshrc|\.bash_profile|\.zprofile|\.zshenv|\.ssh[/\\]authorized_keys)["']?\s*,\s*["']a\+?["']"##),
        LineRule(id: "agent-config", severity: .high, inDocs: .same, pattern: ##"(?i)--dangerously-skip-permissions|\bbypassPermissions\b|--dangerously-bypass-approvals-and-sandbox|\bdanger-full-access\b|--yolo\b|\bskipDangerousModePermissionPrompt\b|\benableAllProjectMcpServers\b|approval_policy\s*=\s*["']never["']|(?:>>?|\btee\b|\bwrite\w*\s*\(|\bSet-Content\b|\bjq\b|\bsed\s+-i\b|\bedit\b|\bmodify\b|\bupdate\b|\badd\b|\bappend\b|\boverwrite\b)[^\n]{0,80}(?:\.claude[/\\]settings(?:\.local)?\.json|\.claude\.json|\.codex[/\\]config\.toml|\.gemini[/\\]settings\.json|\.cursor[/\\](?:mcp|cli-config)\.json|\.codex[/\\]hooks\.json)|\bclaude\s+mcp\s+add\b|\bcodex\s+mcp\s+add\b|\bgemini\s+mcp\s+add\b"##),
        LineRule(id: "pkg-remote", severity: .high, inDocs: .lower, pattern: ##"(?i)\b(?:pip\d?|uv\s+pip|pipx|uv\s+tool)\s+install\b[^\n]*(?:https?://|git\+|--index-url|--extra-index-url|-i\s+https?://)|\b(?:npm|pnpm|yarn|bun)\s+(?:install|i|add)\b[^\n]*(?:https?://|git\+|github:|--registry)|\bgem\s+install\b[^\n]*--source|\bbrew\s+(?:install|tap)\b[^\n]*https?://|\bgo\s+install\s+[^\n]*@(?:latest|master|main)\b|\bcargo\s+install\b[^\n]*--git\b"##),
        LineRule(id: "pkg-install", severity: .medium, inDocs: .lower, pattern: ##"(?i)\b(?:pip\d?|pipx)\s+install\b|\buv\s+(?:pip\s+install|add|tool\s+install)\b|\buvx\s+\S|\bnpm\s+(?:install|i|add|ci|exec)\b|\bnpx\s+\S|\bpnpm\s+(?:add|install|dlx)\b|\byarn\s+(?:add|install|dlx)\b|\bbunx?\s+(?:add|install|x)\b|\bbrew\s+install\b|\bapt(?:-get)?\s+install\b|\b(?:dnf|yum|pacman|apk)\s+(?:install|add|-S)\b|\bcargo\s+install\b|\bgo\s+install\b|\bgem\s+install\b|\bwinget\s+install\b|\bchoco\s+install\b|\bscoop\s+install\b|\bInstall-Module\b|\bdeno\s+(?:install|run)\s+[^\n]*https?://"##),
        LineRule(id: "long-base64", severity: .high, inDocs: .lower, pattern: ##"[A-Za-z0-9+/]{240,}={0,2}"##),
        LineRule(id: "long-hex", severity: .medium, inDocs: .lower, pattern: ##"(?:\\x[0-9a-fA-F]{2}){24,}|\b[0-9a-fA-F]{320,}\b|(?:0x[0-9a-fA-F]{2},\s*){24,}|(?:%[0-9a-fA-F]{2}){40,}"##),
        LineRule(id: "char-codes", severity: .medium, inDocs: .lower, pattern: ##"(?i)fromCharCode\s*\(\s*(?:\d+\s*,\s*){8,}|(?:\bchr\s*\(\s*\d+\s*\)\s*[+.]\s*){5,}|(?:\[char\]\s*\d+\s*\+\s*){5,}|(?:\\u00[0-9a-f]{2}){16,}|(?:\\[0-7]{3}){16,}"##),
        LineRule(id: "packed-code", severity: .medium, inDocs: .skip, pattern: ##"(?i)\bzlib\.decompress\b|\bgzip\.decompress\b|\blzma\.decompress\b|\bbz2\.decompress\b|\bmarshal\.loads\b|IO\.Compression\.\w+Stream|\bzlib\.(?:inflate|gunzip|unzip)(?:Sync)?\b|\beval\s*\(\s*function\s*\(\s*p\s*,\s*a\s*,\s*c\s*,\s*k|\b_0x[0-9a-f]{4,}\b"##),
        LineRule(id: "pi-override", severity: .high, inDocs: .same, pattern: ##"(?i)\b(?:ignore|disregard|forget|override|bypass)\s+(?:all\s+|any\s+|the\s+|your\s+|every\s+)*(?:previous|prior|above|earlier|preceding|existing|original|system|other)\s+(?:instructions?|rules?|prompts?|guidelines?|directives?|messages?|constraints?)|\b(?:note|message|instructions?)\s+(?:to|for)\s+(?:the\s+|any\s+)?(?:security\s+|safety\s+|ai\s+)?(?:reviewer|auditor|scanner|checker|moderator)s?\b|\b(?:already|previously)\s+(?:been\s+)?(?:audited|approved|vetted|verified|whitelisted)\s+(?:by|as)\b|\byour\s+(?:answer|verdict|reply|response|output)\s+must\s+be\b|\bnew\s+system\s+prompt\b|\byou\s+are\s+now\s+(?:in\s+)?(?:developer|dan|unrestricted|jailbreak|god)\b|\bthese\s+instructions\s+(?:override|supersede|take\s+precedence)|\b(?:игнорируй|забудь|проигнорируй|отмени)\s+(?:все\s+|любые\s+)?(?:предыдущие|прежние|прошлые|системные)\s+(?:инструкции|указания|правила)|\b(?:ігноруй|забудь)\s+(?:усі\s+|всі\s+)?(?:попередні|системні)\s+(?:інструкції|вказівки|правила)|\bignoriere\s+(?:alle\s+)?(?:vorherigen|bisherigen)\s+(?:anweisungen|regeln)"##),
        LineRule(id: "pi-conceal", severity: .high, inDocs: .same, pattern: ##"(?i)\b(?:do\s+not|don'?t|never)\s+(?:tell|inform|mention|reveal|show|notify|alert|disclose|report)\b[^\n.]{0,40}\b(?:the\s+)?(?:user|human|operator|person)\b|\bwithout\s+(?:telling|informing|notifying|asking|alerting|prompting)\s+(?:the\s+)?(?:user|human)\b|\b(?:there\s+is\s+)?no\s+need\s+to\s+(?:tell|inform|mention|notify|ask|alert|show)\b[^\n.]{0,40}\b(?:the\s+)?(?:user|human|person)\b|\b(?:the\s+)?(?:user|human)\s+(?:doesn'?t|does\s+not|need\s+not|shouldn'?t|should\s+not)\s+(?:need\s+to\s+)?(?:know|see|be\s+told|notice)\b|\bwithout\s+(?:the\s+)?(?:user|human)(?:'s)?\s+(?:knowledge|consent|confirmation|approval|permission|awareness)\b|\bhide\s+(?:this|it|these|that)\s+from\s+(?:the\s+)?(?:user|human)\b|\bkeep\s+(?:this|it)\s+(?:a\s+)?secret\b|\b(?:silently|secretly|quietly|covertly)\s+(?:send|upload|post|run|execute|install|delete|modify|copy|read|collect|transmit|add|write)\b|\bне\s+(?:говори|сообщай|показывай|упоминай|рассказывай|уведомляй)\b[^\n.]{0,30}пользовател|\bбез\s+ведома\s+пользователя|\b(?:втайне|тайно|скрытно|незаметно)\s+(?:отправ|загруз|выполн|установ|удал|скопир)|\bне\s+(?:кажи|повідомляй|показуй)\b[^\n.]{0,30}користувач|\bohne\s+(?:wissen|zustimmung)\s+des\s+(?:nutzers|benutzers)"##),
        LineRule(id: "pi-disable-safety", severity: .high, inDocs: .same, pattern: ##"(?i)\b(?:disable|turn\s+off|bypass|skip|ignore|circumvent|suppress|remove)\s+(?:all\s+|any\s+|the\s+|every\s+)*(?:safety|security|permission|approval|confirmation|sandbox|guardrail|verification)s?(?:\s+(?:checks?|prompts?|rules?|restrictions?|filters?|mode|requests?|dialogs?))?\b|\bauto-?approve\s+(?:all|every|any)\b|\balways\s+(?:allow|approve|accept|grant)\s+(?:all|every|any)\b|\b(?:do\s+not|don'?t|never)\s+ask\s+(?:for\s+)?(?:the\s+user\s+for\s+)?(?:permission|confirmation|approval)\b|\b(?:отключи|выключи|обойди|пропусти|игнорируй)\s+(?:все\s+)?(?:проверки|защиту|подтверждени\w+|ограничени\w+|песочниц\w+)|\bне\s+(?:спрашивай|запрашивай)\s+(?:разрешени\w+|подтверждени\w+)|\b(?:вимкни|обійди)\s+(?:усі\s+)?(?:перевірки|захист)"##),
        LineRule(id: "pi-exfil", severity: .critical, inDocs: .same, pattern: ##"(?i)\b(?:send|upload|post|forward|transmit|exfiltrate|e-?mail|submit|leak|copy|append|include)\b[^\n.]{0,80}\b(?:credentials?|secrets?|api[\s_-]?keys?|tokens?|passwords?|ssh\s+keys?|private\s+keys?|\.env\b|conversation|chat\s+history|environment\s+variables?|cookies|session\s+data|source\s+code|\.ssh\b|\.aws\b)[^\n.]{0,80}\b(?:to|at|via|into|in)\s+(?:https?://|[a-z0-9-]+(?:\.[a-z0-9-]+)+/|the\s+(?:url|endpoint|server|webhook|address))|(?:\b(?:credentials?|secrets?|api[\s_-]?keys?|tokens?|passwords?|ssh\s+keys?|private\s+keys?|environment\s+variables?|cookies)\b|\.env\b)[^\n.]{0,80}\b(?:send|upload|post|forward|transmit|include|attach|e-?mail|submit|put)\b[^\n.]{0,60}\b(?:to|at|via|into|in)\s+(?:a\s+(?:request|message|call)\s+to\s+)?(?:https?://|[a-z0-9-]+(?:\.[a-z0-9-]+)+/|the\s+(?:url|endpoint|server|webhook|address))|\b(?:отправь|отправляй|загрузи|перешли|передай|скопируй)\b[^\n.]{0,80}(?:ключ|токен|парол|секрет|переписк|\.env|учётн|учетн)[^\n.]{0,80}(?:на|в)\s+(?:https?://|[a-z0-9-]+\.[a-z]{2,}|адрес|сервер)|\b(?:надішли|завантаж|передай)\b[^\n.]{0,80}(?:ключ|токен|парол|секрет)[^\n.]{0,80}(?:на|до)\s+(?:https?://|адрес|сервер)"##),
        LineRule(id: "pi-role", severity: .medium, inDocs: .same, pattern: ##"(?i)<\s*/?\s*(?:system|assistant|im_start|im_end)\s*>|\[\s*/?\s*(?:INST|SYSTEM)\s*\]|<\|(?:im_start|im_end|system|endoftext)\|>|^\s*(?:system|assistant)\s*:\s*(?:you|ignore|always|never)\b|\bsystem-reminder\b"##),
    ]

    /// A hidden HTML comment is only a finding when it reads like an order to the agent.
    static let commentOrder = ##"(?i)\b(?:ignore|disregard|system\s+prompt|you\s+must|do\s+not\s+tell|don'?t\s+tell|execute|run\s+the\s+following|run\s+this|send|upload|curl|wget|secret|password|credentials?|instructions?|token|игнорируй|выполни|отправь|инструкци)\b"##

    /// The rules compiled once.
    static let compiled: [(rule: LineRule, regex: NSRegularExpression)] = lineRules.map { rule in
        let pattern = rule.pattern.replacingOccurrences(of: "SECRET_FILES", with: secretFiles)
        do {
            return (rule, try NSRegularExpression(pattern: pattern))
        } catch {
            fatalError("rule \(rule.id): \(error)")
        }
    }

    /// Every rule's category. The words that explain a rule live in the string catalog, under `SkillRuleText`.
    static let categories: [String: SkillCategory] = [
        "scripts-present": .scripts,
        "executable-binary": .scripts,
        "archive": .scripts,
        "unknown-binary": .scripts,
        "minified": .obfuscation,
        "symlink": .scripts,
        "large-file": .scripts,
        "not-walked": .dependencies,
        "truncated": .scripts,
        "net-call": .network,
        "net-upload": .network,
        "exfil-endpoint": .network,
        "hardcoded-ip": .network,
        "pipe-to-shell": .execution,
        "decode-exec": .execution,
        "dynamic-exec": .execution,
        "secret-read": .secrets,
        "sensitive-path": .secrets,
        "env-dump": .secrets,
        "env-secret": .secrets,
        "dotenv-read": .secrets,
        "exfil-combo": .secrets,
        "rm-rf-home": .system,
        "rm-rf": .system,
        "sudo": .system,
        "chmod-open": .system,
        "persistence": .system,
        "shell-rc": .system,
        "agent-config": .system,
        "pkg-install": .dependencies,
        "pkg-remote": .dependencies,
        "typosquat": .dependencies,
        "long-base64": .obfuscation,
        "long-hex": .obfuscation,
        "char-codes": .obfuscation,
        "packed-code": .obfuscation,
        "pi-override": .injection,
        "pi-conceal": .injection,
        "pi-disable-safety": .injection,
        "pi-exfil": .injection,
        "pi-role": .injection,
        "pi-hidden-text": .injection,
        "pi-hidden-comment": .injection,
        "invisible-tags": .injection,
        "invisible-bidi": .injection,
        "invisible-chars": .injection,
        "hook-command": .plugin,
        "hook-network": .plugin,
        "mcp-server": .plugin,
        "mcp-remote-code": .plugin,
        "mcp-insecure-url": .plugin,
        "broad-permissions": .plugin,
        "allowed-tools-shell": .plugin,
        "command-inline-exec": .plugin,
        "no-skill-md": .metadata,
        "frontmatter": .metadata,
        "no-license": .metadata,
    ]

    static func category(_ id: String) -> SkillCategory { categories[id] ?? .metadata }
}
