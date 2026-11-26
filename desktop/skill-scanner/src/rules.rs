//! The rules of level 1: what is looked for in a line of text, and what every rule means in plain words.

use regex::Regex;
use serde::{Deserialize, Serialize};
use std::sync::OnceLock;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    Info,
    Low,
    Medium,
    High,
    Critical,
}

impl Severity {
    pub fn lowered(self) -> Severity {
        match self {
            Severity::Critical => Severity::High,
            Severity::High => Severity::Medium,
            Severity::Medium => Severity::Low,
            Severity::Low | Severity::Info => Severity::Info,
        }
    }

    pub fn weight(self) -> u32 {
        match self {
            Severity::Info => 0,
            Severity::Low => 5,
            Severity::Medium => 15,
            Severity::High => 35,
            Severity::Critical => 80,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Severity::Info => "info",
            Severity::Low => "low",
            Severity::Medium => "medium",
            Severity::High => "high",
            Severity::Critical => "critical",
        }
    }
}

/// What a rule is about; the interface groups findings by it.
pub mod category {
    pub const SCRIPTS: &str = "scripts";
    pub const NETWORK: &str = "network";
    pub const EXECUTION: &str = "execution";
    pub const SECRETS: &str = "secrets";
    pub const SYSTEM: &str = "system";
    pub const DEPENDENCIES: &str = "dependencies";
    pub const OBFUSCATION: &str = "obfuscation";
    pub const INJECTION: &str = "injection";
    pub const PLUGIN: &str = "plugin";
    pub const METADATA: &str = "metadata";
}

/// In a document (SKILL.md, references) most patterns are a mention or an example, not code that runs by itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InDocs {
    /// As serious in a document as in code: the agent may follow it.
    Same,
    /// One step lower.
    Lower,
    /// Not looked for in documents.
    Skip,
}

#[derive(Debug, Clone, Copy)]
pub struct LineRule {
    pub id: &'static str,
    pub severity: Severity,
    pub in_docs: InDocs,
    pub pattern: &'static str,
}

const fn rule(id: &'static str, severity: Severity, in_docs: InDocs, pattern: &'static str) -> LineRule {
    LineRule { id, severity, in_docs, pattern }
}

const fn injection(id: &'static str, severity: Severity, pattern: &'static str) -> LineRule {
    LineRule { id, severity, in_docs: InDocs::Same, pattern }
}

use InDocs::{Lower, Same, Skip};
use Severity::{Critical, High, Low, Medium};

/// Credential files and stores. `.pub` keys and `known_hosts` are not secrets and are filtered out after the match.
pub const SECRET_FILES: &str = r"(?:~|\$HOME|\$\{HOME\}|%USERPROFILE%|\$env:USERPROFILE|/Users/[^/\s]+|/home/[^/\s]+|expanduser\([^)]*)?[/\\]?\.ssh\b|\bid_(?:rsa|ed25519|ecdsa|dsa)\b|\.aws[/\\](?:credentials|config)|\.config[/\\]gcloud|application_default_credentials|\.kube[/\\]config|\.netrc\b|\.npmrc\b|\.pypirc\b|\.gnupg\b|\.docker[/\\]config\.json|\.git-credentials|\.claude[/\\]\.credentials|\.codex[/\\]auth\.json|\.gemini[/\\]oauth_creds|\.config[/\\]gh[/\\]hosts|login\.keychain|Library[/\\]Keychains|find-(?:generic|internet)-password|\bsecret-tool\b|\bkeyring\.get_password|Login Data\b|[/\\]Cookies\b|cookies\.sqlite|logins\.json|key4\.db|Local State\b|wallet\.dat|\.(?:bash|zsh)_history|/etc/shadow|\bSAM\b.*\bSYSTEM\b|CredentialManager|Get-StoredCredential|\bcmdkey\b";

pub const LINE_RULES: &[LineRule] = &[
    // Network.
    rule("net-call", Medium, Lower, r"(?i)\b(?:curl|wget|ncat|netcat|scp|sftp|telnet)\s+\S|\bnc\s+-|\brequests\.(?:get|post|put|patch|delete|request|Session)\b|\burllib\d?\b|\bhttp\.client\b|\bhttpx\.|\baiohttp\b|\bfetch\s*\(|\baxios\b|XMLHttpRequest|\bsocket\.(?:socket|create_connection|connect)\b|\bnet\.(?:connect|createConnection|Socket)\b|Invoke-WebRequest|Invoke-RestMethod|\b(?:iwr|irm)\s+\S|Net\.WebClient|\bDownloadString\b|\bDownloadFile\b|Start-BitsTransfer|\bbitsadmin\b|\bcertutil\b.*-urlcache|\bhttp\.(?:Get|Post)\(|\breqwest\b|\bnode-fetch\b|\bgot\(|\bWebSocket\("),
    rule("net-upload", High, Lower, r#"(?i)\bcurl\b[^\n]*\s(?:-d\b|--data(?:-binary|-raw|-urlencode)?\b|-F\b|--form\b|-T\b|--upload-file\b|-X\s*(?:POST|PUT)\b|--request\s+(?:POST|PUT)\b)|\bwget\b[^\n]*--post-(?:data|file)|\brequests\.(?:post|put)\b|\bhttpx\.(?:post|put)\b|\bmethod\s*[:=]\s*["'](?:POST|PUT)["']|-Method\s+(?:Post|Put)\b|\bUploadString\b|\bUploadFile\b|\burlopen\([^\n]*data\s*=|\bhttp\.Post\(|\.post\(\s*["'`]https?://"#),
    rule("exfil-endpoint", High, Same, r"(?i)discord(?:app)?\.com/api/webhooks|api\.telegram\.org/bot|hooks\.slack\.com/services|pastebin\.com|paste\.ee|hastebin\.com|ghostbin\.|webhook\.site|requestbin\.|pipedream\.net|\bngrok(?:-free)?\.(?:io|app|dev)\b|transfer\.sh|\b0x0\.st\b|file\.io\b|burpcollaborator\.net|interact\.sh|\boast(?:ify)?\.(?:com|fun|live|me|online|pro|site)\b|requestcatcher\.com|beeceptor\.com|\.trycloudflare\.com|serveo\.net|localtunnel\.me"),
    rule("hardcoded-ip", Medium, Lower, r"\b(?:https?|ftp|wss?|tcp)://(?:\d{1,3}\.){3}\d{1,3}\b|/dev/tcp/"),
    // Execution.
    rule("pipe-to-shell", Critical, Same, r"(?i)\b(?:curl|wget|fetch|iwr|irm|Invoke-WebRequest|Invoke-RestMethod)\b[^\n|;]*\|\s*(?:sudo\s+)?(?:(?:ba|z|da|k|fi)?sh|python\d?|node|perl|ruby|php|iex|Invoke-Expression)\b|\b(?:ba|z)?sh\s+<\(\s*(?:curl|wget)\b|\b(?:ba|z)?sh\s+-c\s+[\x22'`]\$\((?:curl|wget)\b|\b(?:iex|Invoke-Expression)\b[^\n]*(?:DownloadString|\birm\b|\biwr\b|Invoke-WebRequest|Invoke-RestMethod)|\beval\s+[\x22'`]?\$\((?:curl|wget)\b|\bsource\s+<\(\s*(?:curl|wget)\b|\bpython\d?\s+-c\s+[^\n]*urlopen[^\n]*\bexec\b|\bexec\s*\([^\n]*(?:urlopen|requests\.get)\b|\bmshta\s+https?://|\bregsvr32\b[^\n]*/i:https?://"),
    rule("decode-exec", Critical, Same, r"(?i)\bbase64\s+(?:-d|-D|--decode)\b[^\n]*\|\s*(?:sudo\s+)?(?:(?:ba|z)?sh|python\d?|node|perl)\b|\b(?:eval|exec)\s*\(?[^\n]*(?:b64decode|base64\s+(?:-d|-D|--decode)|atob\s*\(|fromhex|codecs\.decode|zlib\.decompress|marshal\.loads|unhexlify)|\b(?:iex|Invoke-Expression)\b[^\n]*FromBase64String|-(?:EncodedCommand|enc|ec)\s+[A-Za-z0-9+/=]{20,}|\bnew\s+Function\s*\([^\n]*atob\s*\(|\bxxd\s+-r\b[^\n]*\|\s*(?:ba|z)?sh\b"),
    rule("dynamic-exec", Medium, Lower, r"(?i)\beval\s*\(|\bexec\s*\(|\beval\s+[\x22'`$]|\b(?:ba|z)?sh\s+-c\b|\bshell\s*=\s*True\b|\bos\.(?:system|popen|exec[lv]p?e?)\s*\(|\bchild_process\b|\bexecSync\s*\(|\bnew\s+Function\s*\(|\bInvoke-Expression\b|\biex\s+[\x22'$(]|\b__import__\s*\(|\bimportlib\.import_module\s*\(|\bcompile\s*\([^\n]*[\x22']exec[\x22']|\bStart-Process\b|\bosascript\s+-e\b|\bdo shell script\b|\bpickle\.loads?\s*\(|\bvm\.runIn\w+\s*\("),
    // Secrets.
    rule("secret-read", Critical, Lower, r"(?i)(?:\b(?:cat|cp|tar|zip|scp|rsync|base64|xxd|head|tail|less|more|strings|dd|open|readFile(?:Sync)?|read_text|read_bytes|ReadFile|Get-Content|gc|type|Copy-Item|Compress-Archive|shutil\.copy\w*|glob|listdir|readdir|walk)\b[^\n]{0,80}|<\s*)(?:SECRET_FILES)"),
    rule("sensitive-path", High, Lower, r"(?i)(?:SECRET_FILES)"),
    rule("env-dump", High, Lower, r"(?i)\bprintenv\b(?:\s*$|\s*[|>)])|\$\(\s*env\s*\)|`env`|(?:^|[;&|]\s*)env\s*(?:[|>]|$)|\b(?:dict|json\.dumps|str)\s*\(\s*(?:dict\s*\(\s*)?os\.environ\b|\bos\.environ\.copy\s*\(|JSON\.stringify\s*\(\s*process\.env\s*[,)]|Object\.(?:entries|keys)\s*\(\s*process\.env\s*\)|Get-ChildItem\s+env:|\bgci\s+env:|\bdir\s+env:|(?:^|[;&|]\s*)set\s*>\s*\S|\bexport\s+-p\b"),
    rule("env-secret", Medium, Lower, r"(?:os\.environ(?:\.get)?\s*[\[(]\s*[\x22']|os\.getenv\s*\(\s*[\x22']|process\.env\.|process\.env\[\s*[\x22']|\$env:|\$\{?|ENV\[\s*[\x22']|getenv\s*\(\s*[\x22']|std::env::var\s*\(\s*[\x22'])[A-Z0-9_]*(?:API_?KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|PRIVATE_KEY|ACCESS_KEY)[A-Z0-9_]*"),
    rule("dotenv-read", Low, Skip, r"(?:^|[^A-Za-z0-9_)\]])\.env(?:\.local|\.production|\.prod)?\b"),
    // Destruction and staying in the system.
    rule("rm-rf-home", High, Same, r#"(?i)\brm\s+(?:-[a-z]*\s+)*-[a-z]*(?:r[a-z]*f|f[a-z]*r)[a-z]*\s+(?:--no-preserve-root\s+)?["']?(?:~/\*|\$HOME/\*|/\*|~/|\$HOME/|\$\{HOME\}/?|\$HOME|/Users|/home|/etc|/usr|/var|C:\\|/|~)["']?(?:\s|$|;|&)|\bRemove-Item\b[^\n]*-Recurse[^\n]*(?:\$HOME|\$env:USERPROFILE|C:\\(?:Users)?\s*$)|\b(?:rd|rmdir)\s+/s\s+/q\s+(?:C:\\|%USERPROFILE%)|\bshutil\.rmtree\s*\(\s*(?:os\.path\.expanduser\(\s*["']~["']\s*\)|Path\.home\(\)|["']/["'])|\bmkfs(?:\.\w+)?\s+/dev/|\bdd\s+[^\n]*\bof=/dev/(?:sd|disk|nvme|hd)|:\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:|\bdiskutil\s+erase|\bformat\s+[a-z]:\s*/"#),
    rule("rm-rf", Medium, Lower, r"(?i)\brm\s+(?:-[a-z]*\s+)*-[a-z]*(?:r[a-z]*f|f[a-z]*r)[a-z]*\s|\bshutil\.rmtree\s*\(|\bRemove-Item\b[^\n]*-Recurse[^\n]*-Force|\b(?:rd|rmdir)\s+/s\b|\bdel\s+/[sfq]\b|\bgit\s+clean\s+-[a-z]*f[a-z]*d|\bfs\.rm(?:Sync)?\s*\([^\n]*recursive\s*:\s*true|\bfind\b[^\n]*\s-delete\b"),
    rule("sudo", Medium, Lower, r"(?i)(?:^|[\s;&|`(])sudo\s+\S|\bdoas\s+\S|\bStart-Process\b[^\n]*-Verb\s+RunAs|\brunas\s+/user|\bosascript\b[^\n]*with administrator privileges"),
    rule("chmod-open", Medium, Lower, r"(?i)\bchmod\s+(?:-[a-z]+\s+)*(?:0?777|a\+rwx|ugo\+rwx|o\+w)\b|\bicacls\b[^\n]*Everyone:\(?F|\bchmod\s+[ug]\+s\b|\bxattr\s+-[a-z]*d[a-z]*\s+com\.apple\.quarantine|\bspctl\s+--master-disable|Set-MpPreference\b[^\n]*Disable|Add-MpPreference\s+-ExclusionPath|Set-ExecutionPolicy\s+(?:Bypass|Unrestricted)"),
    rule("persistence", High, Lower, r"(?i)\bLaunchAgents\b|\bLaunchDaemons\b|\blaunchctl\s+(?:load|bootstrap|enable|submit)\b|\bcrontab\b|/etc/cron|/var/spool/cron|\bsystemctl\s+(?:--user\s+)?enable\b|\.config/systemd/user|\.config/autostart|/etc/init\.d/|/etc/rc\.local|/etc/profile\.d/|CurrentVersion\\+Run(?:Once)?\b|\bschtasks\b[^\n]*/create|\bRegister-ScheduledTask\b|\bNew-ScheduledTask\w*\b|Start Menu\\+Programs\\+Startup|\bshell:startup\b|\blogin\s*item|\bLoginHook\b|\bat\s+now\s*\+"),
    rule("shell-rc", High, Lower, r#"(?i)(?:>>?|\btee\b(?:\s+-a)?|\bopen\s*\(|\bappendFile(?:Sync)?\s*\(|\bwriteFile(?:Sync)?\s*\(|\bAdd-Content\b|\bSet-Content\b|\bOut-File\b|\bsed\s+-i\b|\bwrite_text\s*\()[^\n]*(?:\.bashrc|\.zshrc|\.bash_profile|\.zprofile|\.profile\b|\.zshenv|\.zlogin|config\.fish|\$PROFILE\b|Microsoft\.PowerShell_profile\.ps1|\.gitconfig|\.ssh[/\\]authorized_keys|\.ssh[/\\]config)|(?:\.bashrc|\.zshrc|\.bash_profile|\.zprofile|\.zshenv|\.ssh[/\\]authorized_keys)["']?\s*,\s*["']a\+?["']"#),
    rule("agent-config", High, Same, r#"(?i)--dangerously-skip-permissions|\bbypassPermissions\b|--dangerously-bypass-approvals-and-sandbox|\bdanger-full-access\b|--yolo\b|\bskipDangerousModePermissionPrompt\b|\benableAllProjectMcpServers\b|approval_policy\s*=\s*["']never["']|(?:>>?|\btee\b|\bwrite\w*\s*\(|\bSet-Content\b|\bjq\b|\bsed\s+-i\b|\bedit\b|\bmodify\b|\bupdate\b|\badd\b|\bappend\b|\boverwrite\b)[^\n]{0,80}(?:\.claude[/\\]settings(?:\.local)?\.json|\.claude\.json|\.codex[/\\]config\.toml|\.gemini[/\\]settings\.json|\.cursor[/\\](?:mcp|cli-config)\.json|\.codex[/\\]hooks\.json)|\bclaude\s+mcp\s+add\b|\bcodex\s+mcp\s+add\b|\bgemini\s+mcp\s+add\b"#),
    // Dependencies.
    rule("pkg-remote", High, Lower, r"(?i)\b(?:pip\d?|uv\s+pip|pipx|uv\s+tool)\s+install\b[^\n]*(?:https?://|git\+|--index-url|--extra-index-url|-i\s+https?://)|\b(?:npm|pnpm|yarn|bun)\s+(?:install|i|add)\b[^\n]*(?:https?://|git\+|github:|--registry)|\bgem\s+install\b[^\n]*--source|\bbrew\s+(?:install|tap)\b[^\n]*https?://|\bgo\s+install\s+[^\n]*@(?:latest|master|main)\b|\bcargo\s+install\b[^\n]*--git\b"),
    rule("pkg-install", Medium, Lower, r"(?i)\b(?:pip\d?|pipx)\s+install\b|\buv\s+(?:pip\s+install|add|tool\s+install)\b|\buvx\s+\S|\bnpm\s+(?:install|i|add|ci|exec)\b|\bnpx\s+\S|\bpnpm\s+(?:add|install|dlx)\b|\byarn\s+(?:add|install|dlx)\b|\bbunx?\s+(?:add|install|x)\b|\bbrew\s+install\b|\bapt(?:-get)?\s+install\b|\b(?:dnf|yum|pacman|apk)\s+(?:install|add|-S)\b|\bcargo\s+install\b|\bgo\s+install\b|\bgem\s+install\b|\bwinget\s+install\b|\bchoco\s+install\b|\bscoop\s+install\b|\bInstall-Module\b|\bdeno\s+(?:install|run)\s+[^\n]*https?://"),
    // Obfuscation.
    rule("long-base64", High, Lower, r"[A-Za-z0-9+/]{240,}={0,2}"),
    rule("long-hex", Medium, Lower, r"(?:\\x[0-9a-fA-F]{2}){24,}|\b[0-9a-fA-F]{320,}\b|(?:0x[0-9a-fA-F]{2},\s*){24,}|(?:%[0-9a-fA-F]{2}){40,}"),
    rule("char-codes", Medium, Lower, r"(?i)fromCharCode\s*\(\s*(?:\d+\s*,\s*){8,}|(?:\bchr\s*\(\s*\d+\s*\)\s*[+.]\s*){5,}|(?:\[char\]\s*\d+\s*\+\s*){5,}|(?:\\u00[0-9a-f]{2}){16,}|(?:\\[0-7]{3}){16,}"),
    rule("packed-code", Medium, Skip, r"(?i)\bzlib\.decompress\b|\bgzip\.decompress\b|\blzma\.decompress\b|\bbz2\.decompress\b|\bmarshal\.loads\b|IO\.Compression\.\w+Stream|\bzlib\.(?:inflate|gunzip|unzip)(?:Sync)?\b|\beval\s*\(\s*function\s*\(\s*p\s*,\s*a\s*,\s*c\s*,\s*k|\b_0x[0-9a-f]{4,}\b"),
    // Prompt injection: text written for the agent, against the person.
    injection("pi-override", High, r"(?i)\b(?:ignore|disregard|forget|override|bypass)\s+(?:all\s+|any\s+|the\s+|your\s+|every\s+)*(?:previous|prior|above|earlier|preceding|existing|original|system|other)\s+(?:instructions?|rules?|prompts?|guidelines?|directives?|messages?|constraints?)|\b(?:note|message|instructions?)\s+(?:to|for)\s+(?:the\s+|any\s+)?(?:security\s+|safety\s+|ai\s+)?(?:reviewer|auditor|scanner|checker|moderator)s?\b|\b(?:already|previously)\s+(?:been\s+)?(?:audited|approved|vetted|verified|whitelisted)\s+(?:by|as)\b|\byour\s+(?:answer|verdict|reply|response|output)\s+must\s+be\b|\bnew\s+system\s+prompt\b|\byou\s+are\s+now\s+(?:in\s+)?(?:developer|dan|unrestricted|jailbreak|god)\b|\bthese\s+instructions\s+(?:override|supersede|take\s+precedence)|\b(?:игнорируй|забудь|проигнорируй|отмени)\s+(?:все\s+|любые\s+)?(?:предыдущие|прежние|прошлые|системные)\s+(?:инструкции|указания|правила)|\b(?:ігноруй|забудь)\s+(?:усі\s+|всі\s+)?(?:попередні|системні)\s+(?:інструкції|вказівки|правила)|\bignoriere\s+(?:alle\s+)?(?:vorherigen|bisherigen)\s+(?:anweisungen|regeln)"),
    injection("pi-conceal", High, r"(?i)\b(?:do\s+not|don'?t|never)\s+(?:tell|inform|mention|reveal|show|notify|alert|disclose|report)\b[^\n.]{0,40}\b(?:the\s+)?(?:user|human|operator|person)\b|\bwithout\s+(?:telling|informing|notifying|asking|alerting|prompting)\s+(?:the\s+)?(?:user|human)\b|\b(?:there\s+is\s+)?no\s+need\s+to\s+(?:tell|inform|mention|notify|ask|alert|show)\b[^\n.]{0,40}\b(?:the\s+)?(?:user|human|person)\b|\b(?:the\s+)?(?:user|human)\s+(?:doesn'?t|does\s+not|need\s+not|shouldn'?t|should\s+not)\s+(?:need\s+to\s+)?(?:know|see|be\s+told|notice)\b|\bwithout\s+(?:the\s+)?(?:user|human)(?:'s)?\s+(?:knowledge|consent|confirmation|approval|permission|awareness)\b|\bhide\s+(?:this|it|these|that)\s+from\s+(?:the\s+)?(?:user|human)\b|\bkeep\s+(?:this|it)\s+(?:a\s+)?secret\b|\b(?:silently|secretly|quietly|covertly)\s+(?:send|upload|post|run|execute|install|delete|modify|copy|read|collect|transmit|add|write)\b|\bне\s+(?:говори|сообщай|показывай|упоминай|рассказывай|уведомляй)\b[^\n.]{0,30}пользовател|\bбез\s+ведома\s+пользователя|\b(?:втайне|тайно|скрытно|незаметно)\s+(?:отправ|загруз|выполн|установ|удал|скопир)|\bне\s+(?:кажи|повідомляй|показуй)\b[^\n.]{0,30}користувач|\bohne\s+(?:wissen|zustimmung)\s+des\s+(?:nutzers|benutzers)"),
    injection("pi-disable-safety", High, r"(?i)\b(?:disable|turn\s+off|bypass|skip|ignore|circumvent|suppress|remove)\s+(?:all\s+|any\s+|the\s+|every\s+)*(?:safety|security|permission|approval|confirmation|sandbox|guardrail|verification)s?(?:\s+(?:checks?|prompts?|rules?|restrictions?|filters?|mode|requests?|dialogs?))?\b|\bauto-?approve\s+(?:all|every|any)\b|\balways\s+(?:allow|approve|accept|grant)\s+(?:all|every|any)\b|\b(?:do\s+not|don'?t|never)\s+ask\s+(?:for\s+)?(?:the\s+user\s+for\s+)?(?:permission|confirmation|approval)\b|\b(?:отключи|выключи|обойди|пропусти|игнорируй)\s+(?:все\s+)?(?:проверки|защиту|подтверждени\w+|ограничени\w+|песочниц\w+)|\bне\s+(?:спрашивай|запрашивай)\s+(?:разрешени\w+|подтверждени\w+)|\b(?:вимкни|обійди)\s+(?:усі\s+)?(?:перевірки|захист)"),
    injection("pi-exfil", Critical, r"(?i)\b(?:send|upload|post|forward|transmit|exfiltrate|e-?mail|submit|leak|copy|append|include)\b[^\n.]{0,80}\b(?:credentials?|secrets?|api[\s_-]?keys?|tokens?|passwords?|ssh\s+keys?|private\s+keys?|\.env\b|conversation|chat\s+history|environment\s+variables?|cookies|session\s+data|source\s+code|\.ssh\b|\.aws\b)[^\n.]{0,80}\b(?:to|at|via|into|in)\s+(?:https?://|[a-z0-9-]+(?:\.[a-z0-9-]+)+/|the\s+(?:url|endpoint|server|webhook|address))|(?:\b(?:credentials?|secrets?|api[\s_-]?keys?|tokens?|passwords?|ssh\s+keys?|private\s+keys?|environment\s+variables?|cookies)\b|\.env\b)[^\n.]{0,80}\b(?:send|upload|post|forward|transmit|include|attach|e-?mail|submit|put)\b[^\n.]{0,60}\b(?:to|at|via|into|in)\s+(?:a\s+(?:request|message|call)\s+to\s+)?(?:https?://|[a-z0-9-]+(?:\.[a-z0-9-]+)+/|the\s+(?:url|endpoint|server|webhook|address))|\b(?:отправь|отправляй|загрузи|перешли|передай|скопируй)\b[^\n.]{0,80}(?:ключ|токен|парол|секрет|переписк|\.env|учётн|учетн)[^\n.]{0,80}(?:на|в)\s+(?:https?://|[a-z0-9-]+\.[a-z]{2,}|адрес|сервер)|\b(?:надішли|завантаж|передай)\b[^\n.]{0,80}(?:ключ|токен|парол|секрет)[^\n.]{0,80}(?:на|до)\s+(?:https?://|адрес|сервер)"),
    injection("pi-role", Medium, r"(?i)<\s*/?\s*(?:system|assistant|im_start|im_end)\s*>|\[\s*/?\s*(?:INST|SYSTEM)\s*\]|<\|(?:im_start|im_end|system|endoftext)\|>|^\s*(?:system|assistant)\s*:\s*(?:you|ignore|always|never)\b|\bsystem-reminder\b"),
];

/// A hidden HTML comment is only a finding when it reads like an order to the agent.
pub const COMMENT_ORDER: &str = r"(?i)\b(?:ignore|disregard|system\s+prompt|you\s+must|do\s+not\s+tell|don'?t\s+tell|execute|run\s+the\s+following|run\s+this|send|upload|curl|wget|secret|password|credentials?|instructions?|token|игнорируй|выполни|отправь|инструкци)\b";

pub fn compiled() -> &'static [(LineRule, Regex)] {
    static RULES: OnceLock<Vec<(LineRule, Regex)>> = OnceLock::new();
    RULES.get_or_init(|| {
        LINE_RULES
            .iter()
            .map(|rule| {
                let pattern = rule.pattern.replace("SECRET_FILES", SECRET_FILES);
                (*rule, Regex::new(&pattern).unwrap_or_else(|error| panic!("rule {}: {error}", rule.id)))
            })
            .collect()
    })
}

pub fn regex(cell: &'static OnceLock<Regex>, pattern: &str) -> &'static Regex {
    cell.get_or_init(|| Regex::new(pattern).expect("a rule's pattern"))
}

// MARK: - Every rule in plain words

#[derive(Debug, Clone, Copy, Serialize)]
pub struct RuleInfo {
    pub id: &'static str,
    pub category: &'static str,
    /// A few words: what was found.
    pub title: &'static str,
    /// Why it matters, for someone who doesn't read code.
    pub why: &'static str,
}

const fn info(id: &'static str, category: &'static str, title: &'static str, why: &'static str) -> RuleInfo {
    RuleInfo { id, category, title, why }
}

use category::*;

pub const RULES: &[RuleInfo] = &[
    info("scripts-present", SCRIPTS, "Contains a script", "The agent can run this file on your computer with your rights. Read it before you trust the skill."),
    info("executable-binary", SCRIPTS, "Contains a compiled program", "A compiled program can't be read, so nobody can tell what it does. A skill rarely needs one."),
    info("archive", SCRIPTS, "Contains an archive", "The files inside an archive are not checked. It can carry code that is unpacked later."),
    info("unknown-binary", SCRIPTS, "Contains a file that is not text", "The file can't be read as text and is not a known picture or font, so it was not checked."),
    info("minified", OBFUSCATION, "Code packed into very long lines", "Minified or packed code is hard to read, which makes it a convenient place to hide something."),
    info("symlink", SCRIPTS, "Contains a link to another place", "A link can point outside the skill, at your own files. Links are never followed or installed."),
    info("large-file", SCRIPTS, "A file too large to check", "The file is over the size limit and its content was not checked."),
    info("not-walked", DEPENDENCIES, "Bundled dependencies were not checked", "The folder holds third-party packages (for example node_modules). They can run with the skill and were not checked."),
    info("truncated", SCRIPTS, "Too many files to check them all", "The skill is larger than the limits, so part of it was not checked."),
    info("net-call", NETWORK, "Talks to the network", "The code or the instructions reach out to the internet. Check where to and what is sent."),
    info("net-upload", NETWORK, "Sends data out", "Data is sent to a server (POST, upload). Check that it is not your files or keys."),
    info("exfil-endpoint", NETWORK, "Uses a service often used to steal data", "Webhooks, paste sites and tunnels are a common way to carry stolen data out, because they need no server of the attacker's own."),
    info("hardcoded-ip", NETWORK, "Connects to a bare IP address", "A real service has a name. An address written as numbers is usually someone's private server."),
    info("pipe-to-shell", EXECUTION, "Downloads code and runs it at once", "Whatever the server answers is run on your computer, and it can answer something different tomorrow. Nothing here can be checked in advance."),
    info("decode-exec", EXECUTION, "Decodes hidden text and runs it", "The real commands are hidden in encoded form and only appear at the moment they run. Honest code has no reason to do that."),
    info("dynamic-exec", EXECUTION, "Builds and runs commands on the fly", "A command put together from text at run time can become anything, including what the author never showed."),
    info("secret-read", SECRETS, "Reads your keys or passwords", "The code opens files where SSH keys, cloud credentials, browser logins or agent tokens are kept."),
    info("sensitive-path", SECRETS, "Mentions where keys and passwords are kept", "The skill refers to folders with SSH keys, cloud credentials, the keychain or browser profiles."),
    info("env-dump", SECRETS, "Collects every environment variable", "Environment variables often hold API keys and tokens. Collecting all of them at once is how they are stolen."),
    info("env-secret", SECRETS, "Reads a key or token from the environment", "Normal for a tool that needs an API key, but check that the key goes only to the service it belongs to."),
    info("dotenv-read", SECRETS, "Works with a .env file", ".env files usually hold a project's keys and passwords."),
    info("exfil-combo", SECRETS, "Reads secrets and sends data out", "The same file both reaches for keys or passwords and sends data to the network. Together that is how credentials are stolen."),
    info("rm-rf-home", SYSTEM, "Can erase your files or a disk", "The command deletes a home folder, a system folder or a whole disk without asking."),
    info("rm-rf", SYSTEM, "Deletes folders without asking", "A forced recursive delete. With a wrong path it removes much more than intended."),
    info("sudo", SYSTEM, "Asks for administrator rights", "With administrator rights a command can change anything in the system."),
    info("chmod-open", SYSTEM, "Weakens the system's protection", "Opens files to everyone, removes the quarantine mark or switches off a system safeguard."),
    info("persistence", SYSTEM, "Starts itself with the system", "Autostart, a scheduled task or a background service: the code keeps running after the skill has done its job, even after a restart."),
    info("shell-rc", SYSTEM, "Changes your terminal's start-up files", "What is written into .zshrc, a profile or authorized_keys runs in every new terminal or opens the door to your account."),
    info("agent-config", SYSTEM, "Changes the agent's permissions", "Switching off permission prompts or adding servers and hooks to the agent's settings lets later commands run without asking you."),
    info("pkg-install", DEPENDENCIES, "Installs packages", "Installed packages run their own code. They are not part of the skill and were not checked."),
    info("pkg-remote", DEPENDENCIES, "Installs a package from an unusual place", "The package comes from a link or another registry, not from the usual store, so nobody reviewed it."),
    info("typosquat", DEPENDENCIES, "A package name that looks like a typo", "The name is one letter away from a popular package. Fake packages with such names are a known way to plant malware."),
    info("long-base64", OBFUSCATION, "A long block of encoded text", "Encoded text hides what it really is. It may be a picture, or it may be a program."),
    info("long-hex", OBFUSCATION, "A long block of hex codes", "Text written as codes instead of letters can't be read at a glance, which is the point of hiding it."),
    info("char-codes", OBFUSCATION, "Text built from character codes", "Words assembled from numbers are invisible to a search and to a reader."),
    info("packed-code", OBFUSCATION, "Unpacks code at run time", "Compressed or scrambled code only shows itself when it runs."),
    info("pi-override", INJECTION, "Tells the agent to ignore its instructions", "The text tries to replace the rules the agent works by. A skill should add knowledge, not cancel rules."),
    info("pi-conceal", INJECTION, "Tells the agent to hide something from you", "An honest skill has nothing to do behind your back."),
    info("pi-disable-safety", INJECTION, "Tells the agent to switch off checks", "The text asks the agent to stop asking for your permission or to work around its safeguards."),
    info("pi-exfil", INJECTION, "Tells the agent to send your data somewhere", "The instructions ask to pass keys, passwords or your conversation to an outside address."),
    info("pi-role", INJECTION, "Imitates a system message", "The text is dressed up as a message from the system so the agent trusts it more than it should."),
    info("pi-hidden-text", INJECTION, "An instruction hidden with invisible characters", "Invisible characters break up a phrase so that you and simple filters don't see it, while the agent still reads it."),
    info("pi-hidden-comment", INJECTION, "An instruction in a hidden comment", "The comment is not shown when the file is displayed, but the agent reads it. Orders don't belong there."),
    info("invisible-tags", INJECTION, "Hidden text in invisible Unicode tags", "These characters are never shown on screen and are used to smuggle whole sentences to the agent."),
    info("invisible-bidi", INJECTION, "Characters that reorder text on screen", "The text you see is not in the order the agent reads it, so the visible meaning can differ from the real one."),
    info("invisible-chars", INJECTION, "Invisible characters in the text", "Zero-width characters are not shown on screen. A few can be a copy-paste accident; many usually hide something."),
    info("hook-command", PLUGIN, "Adds a hook: a command that runs by itself", "A hook runs on an agent event (a session start, before a tool) without asking each time."),
    info("hook-network", PLUGIN, "A hook that talks to the network", "This command runs automatically and reaches out to the internet, so data can leave without you noticing."),
    info("mcp-server", PLUGIN, "Adds an MCP server", "An MCP server is a program or an outside service that gives the agent new tools and sees what is sent to them."),
    info("mcp-remote-code", PLUGIN, "An MCP server downloaded at every start", "The server is fetched from a package store when it starts, with no fixed version. What runs can change at any time."),
    info("mcp-insecure-url", PLUGIN, "An MCP server over an unprotected connection", "The address is plain http or a bare IP: what is sent to it can be read or replaced on the way."),
    info("broad-permissions", PLUGIN, "Grants itself wide permissions", "The settings allow any command or switch off permission prompts."),
    info("allowed-tools-shell", PLUGIN, "May run any shell command without asking", "The skill or command pre-approves the shell tool with no limits."),
    info("command-inline-exec", PLUGIN, "A slash command that runs a shell command", "The command's text is run as soon as the slash command is used, before the agent reads anything."),
    info("no-skill-md", METADATA, "No valid SKILL.md", "The folder has no SKILL.md with a name and a description, so it is not a skill by the Agent Skills standard."),
    info("frontmatter", METADATA, "SKILL.md doesn't follow the standard", "The name or the description breaks the Agent Skills rules. Some agents won't load such a skill."),
    info("no-license", METADATA, "No license", "Without a license it is unclear on what terms the skill may be used or shared."),
];

pub fn info_of(id: &str) -> Option<&'static RuleInfo> {
    RULES.iter().find(|rule| rule.id == id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_line_rule_compiles_and_is_explained() {
        for (rule, _) in compiled() {
            assert!(info_of(rule.id).is_some(), "{} has no explanation", rule.id);
        }
        let mut ids: Vec<&str> = RULES.iter().map(|rule| rule.id).collect();
        ids.sort_unstable();
        let before = ids.len();
        ids.dedup();
        assert_eq!(ids.len(), before, "a rule is explained twice");
    }
}
