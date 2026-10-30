import Foundation

/// The language of what ClaudePult writes and sends, not only shows: prompts for AI services, new cards and content
/// plans, template texts. It follows the interface language; Russian is the default.
enum ContentLanguage: String, CaseIterable, Sendable {
    case ru, en, es
    case ptBR = "pt-BR"
    case fr, de, ja, id, ko, it, ar, pl, uk

    static var current: ContentLanguage {
        Bundle.main.preferredLocalizations.first.flatMap { code in allCases.first { code.hasPrefix($0.rawValue) } } ?? .ru
    }

    var strings: ContentStrings {
        switch self {
        case .ru: .russian
        case .en: .english
        case .es: .spanish
        case .ptBR: .portuguese
        case .fr: .french
        case .de: .german
        case .ja: .japanese
        case .id: .indonesian
        case .ko: .korean
        case .it: .italian
        case .ar: .arabic
        case .pl: .polish
        case .uk: .ukrainian
        }
    }
}

/// Everything a language needs for files and prompts. `{project}`, `{file}`, `{output}`, `{format}`, `{task}` are
/// filled in by `CommandText`; adding a language is adding one of these.
struct ContentStrings: Sendable {
    var cardFile: String
    var planFile: String
    /// stage, deadline, publish, format, main file, platform — as written into a new card.
    var cardLabels: [ProjectCardFile.Key: String]
    var notesHeading: String
    var planTitle: String
    var planColumns: [ContentPlan.Column: String]
    var ideaStatus: String
    var notSet: String
    var notCounted: String
    var projectWord: String
    var resultWord: String
    var agentPrompt: String
    var agentNoFile: String
    var apiHeader: String
    var apiFileIntro: String
    var apiTask: String
    var apiRule: String
    var nextStep: String
    var customTask: String
    var finishSession: String
    /// How a custom task starts and where the task text ends, to show it as a session title.
    var taskPrefix: String
    var rulesMarker: String

    static let russian = ContentStrings(
        cardFile: "проект.md", planFile: "контент-план.md",
        cardLabels: [.stage: "Этап", .deadline: "Дедлайн", .publish: "Публикация", .format: "Формат", .mainFile: "Главный файл", .platform: "Площадка"],
        notesHeading: "## Заметки", planTitle: "# Контент-план",
        planColumns: [.date: "Дата", .time: "Время", .platform: "Площадка", .topic: "Тема", .status: "Статус", .file: "Файл"],
        ideaStatus: "идея", notSet: "не указан", notCounted: "не посчитан", projectWord: "проект", resultWord: "результат",
        agentPrompt: """
        Ты работаешь в папке проекта «{project}». Исходный файл: {file}. \
        Читай любые файлы этой папки, но ничего в них не меняй. Результат запиши в новый файл {output} в этой же папке. \
        Если задача неясна или данных не хватает — напиши об этом в начале файла результата, не выдумывай.

        Задача: {task}
        """,
        agentNoFile: "нет — работай с файлами папки",
        apiHeader: "Проект: «{project}». Формат: {format}.",
        apiFileIntro: "Ниже — текст файла «{file}».",
        apiTask: "Задача: {task}",
        apiRule: "Ответь только результатом в Markdown, без вступлений и пояснений. Если данных не хватает — скажи об этом первой строкой, не выдумывай.",
        nextStep: "Прочитай README и, если есть, docs/STATUS.md, CLAUDE.md или AGENTS.md. Определи следующий разумный шаг: первый пункт списка «Next / Дальше», если он есть, иначе самую очевидную незаконченную задачу. Сделай его в отдельной ветке от основной: изменения, проверки проекта (тесты, сборка, линтер — что есть), коммит с понятным сообщением, push и pull request. Если шаг требует решения человека или неясен — ничего не меняй, а коротко опиши вопрос.",
        customTask: "Задача: {task}. Работай по правилам проекта (CLAUDE.md / AGENTS.md, если они есть): отдельная ветка от основной, проверки проекта, коммит, push, pull request.",
        finishSession: "Доведи до конца текущую работу в этой папке: прогони проверки проекта, разложи незакоммиченные изменения по смыслу на коммиты (если они относятся к разным задачам — по отдельным веткам), сделай push и pull request. Новых изменений кода не делай.",
        taskPrefix: "Задача: ", rulesMarker: ". Работай по правилам"
    )

    static let english = ContentStrings(
        cardFile: "project.md", planFile: "content-plan.md",
        cardLabels: [.stage: "Stage", .deadline: "Deadline", .publish: "Publish", .format: "Format", .mainFile: "Main file", .platform: "Platform"],
        notesHeading: "## Notes", planTitle: "# Content plan",
        planColumns: [.date: "Date", .time: "Time", .platform: "Platform", .topic: "Topic", .status: "Status", .file: "File"],
        ideaStatus: "idea", notSet: "not set", notCounted: "not counted", projectWord: "project", resultWord: "result",
        agentPrompt: """
        You are working in the folder of the project «{project}». Source file: {file}. \
        Read any files of this folder but change none of them. Write the result to a new file {output} in the same folder. \
        If the task is unclear or data is missing, say so at the top of the result file — do not make things up.

        Task: {task}
        """,
        agentNoFile: "none — work with the files of the folder",
        apiHeader: "Project: «{project}». Format: {format}.",
        apiFileIntro: "Below is the text of the file «{file}».",
        apiTask: "Task: {task}",
        apiRule: "Reply with the result only, in Markdown, without introductions or explanations. If data is missing, say so in the first line — do not make things up.",
        nextStep: "Read the README and, if present, docs/STATUS.md, CLAUDE.md or AGENTS.md. Find the next sensible step: the first item of the «Next» list if there is one, otherwise the most obvious unfinished task. Do it on a separate branch from the main one: the changes, the project's checks (tests, build, linter — whatever exists), a commit with a clear message, push and a pull request. If the step needs a person's decision or is unclear, change nothing and briefly describe the question.",
        customTask: "Task: {task}. Follow the project's rules (CLAUDE.md / AGENTS.md if present): a separate branch from the main one, the project's checks, commit, push, pull request.",
        finishSession: "Finish the current work in this folder: run the project's checks, split uncommitted changes into commits by meaning (onto separate branches if they belong to different tasks), push and open a pull request. Make no new code changes.",
        taskPrefix: "Task: ", rulesMarker: ". Follow the project's rules"
    )

    static let spanish = ContentStrings(
        cardFile: "proyecto.md", planFile: "plan-de-contenido.md",
        cardLabels: [.stage: "Etapa", .deadline: "Fecha límite", .publish: "Publicación", .format: "Formato", .mainFile: "Archivo principal", .platform: "Plataforma"],
        notesHeading: "## Notas", planTitle: "# Plan de contenido",
        planColumns: [.date: "Fecha", .time: "Hora", .platform: "Plataforma", .topic: "Tema", .status: "Estado", .file: "Archivo"],
        ideaStatus: "idea", notSet: "sin indicar", notCounted: "sin calcular", projectWord: "proyecto", resultWord: "resultado",
        agentPrompt: """
        Trabajas en la carpeta del proyecto «{project}». Archivo de origen: {file}. \
        Lee cualquier archivo de esta carpeta, pero no modifiques ninguno. Escribe el resultado en un archivo nuevo {output} en la misma carpeta. \
        Si la tarea no está clara o faltan datos, dilo al principio del archivo de resultado; no inventes nada.

        Tarea: {task}
        """,
        agentNoFile: "ninguno — trabaja con los archivos de la carpeta",
        apiHeader: "Proyecto: «{project}». Formato: {format}.",
        apiFileIntro: "A continuación, el texto del archivo «{file}».",
        apiTask: "Tarea: {task}",
        apiRule: "Responde solo con el resultado en Markdown, sin introducciones ni explicaciones. Si faltan datos, dilo en la primera línea; no inventes nada.",
        nextStep: "Lee el README y, si existen, docs/STATUS.md, CLAUDE.md o AGENTS.md. Determina el siguiente paso razonable: el primer punto de la lista «Next / Siguiente» si existe; si no, la tarea pendiente más evidente. Hazlo en una rama aparte de la principal: los cambios, las comprobaciones del proyecto (tests, build, linter — lo que haya), un commit con un mensaje claro, push y un pull request. Si el paso requiere la decisión de una persona o no está claro, no cambies nada y describe brevemente la pregunta.",
        customTask: "Tarea: {task}. Sigue las reglas del proyecto (CLAUDE.md / AGENTS.md si existen): una rama aparte de la principal, las comprobaciones del proyecto, commit, push, pull request.",
        finishSession: "Termina el trabajo actual en esta carpeta: ejecuta las comprobaciones del proyecto, reparte los cambios sin commit en commits según su sentido (en ramas separadas si pertenecen a tareas distintas), haz push y abre un pull request. No hagas cambios de código nuevos.",
        taskPrefix: "Tarea: ", rulesMarker: ". Sigue las reglas"
    )

    static let portuguese = ContentStrings(
        cardFile: "projeto.md", planFile: "plano-de-conteudo.md",
        cardLabels: [.stage: "Etapa", .deadline: "Prazo", .publish: "Publicação", .format: "Formato", .mainFile: "Arquivo principal", .platform: "Plataforma"],
        notesHeading: "## Notas", planTitle: "# Plano de conteúdo",
        planColumns: [.date: "Data", .time: "Hora", .platform: "Plataforma", .topic: "Tema", .status: "Status", .file: "Arquivo"],
        ideaStatus: "ideia", notSet: "não informado", notCounted: "não calculado", projectWord: "projeto", resultWord: "resultado",
        agentPrompt: """
        Você está trabalhando na pasta do projeto «{project}». Arquivo de origem: {file}. \
        Leia qualquer arquivo desta pasta, mas não altere nenhum. Escreva o resultado em um novo arquivo {output} na mesma pasta. \
        Se a tarefa não estiver clara ou faltarem dados, diga isso no início do arquivo de resultado — não invente nada.

        Tarefa: {task}
        """,
        agentNoFile: "nenhum — trabalhe com os arquivos da pasta",
        apiHeader: "Projeto: «{project}». Formato: {format}.",
        apiFileIntro: "Abaixo está o texto do arquivo «{file}».",
        apiTask: "Tarefa: {task}",
        apiRule: "Responda apenas com o resultado em Markdown, sem introduções nem explicações. Se faltarem dados, diga isso na primeira linha — não invente nada.",
        nextStep: "Leia o README e, se existirem, docs/STATUS.md, CLAUDE.md ou AGENTS.md. Defina o próximo passo sensato: o primeiro item da lista «Next / Próximo», se houver; caso contrário, a tarefa inacabada mais óbvia. Faça-o em um branch separado do principal: as mudanças, as verificações do projeto (testes, build, linter — o que existir), um commit com mensagem clara, push e um pull request. Se o passo exigir a decisão de uma pessoa ou não estiver claro, não altere nada e descreva a dúvida brevemente.",
        customTask: "Tarefa: {task}. Siga as regras do projeto (CLAUDE.md / AGENTS.md, se existirem): um branch separado do principal, as verificações do projeto, commit, push, pull request.",
        finishSession: "Conclua o trabalho atual nesta pasta: rode as verificações do projeto, divida as mudanças sem commit em commits por assunto (em branches separados se forem de tarefas diferentes), faça push e abra um pull request. Não faça novas mudanças de código.",
        taskPrefix: "Tarefa: ", rulesMarker: ". Siga as regras"
    )

    static let french = ContentStrings(
        cardFile: "projet.md", planFile: "plan-de-contenu.md",
        cardLabels: [.stage: "Étape", .deadline: "Échéance", .publish: "Publication", .format: "Format", .mainFile: "Fichier principal", .platform: "Plateforme"],
        notesHeading: "## Notes", planTitle: "# Plan de contenu",
        planColumns: [.date: "Date", .time: "Heure", .platform: "Plateforme", .topic: "Sujet", .status: "Statut", .file: "Fichier"],
        ideaStatus: "idée", notSet: "non précisé", notCounted: "non calculé", projectWord: "projet", resultWord: "résultat",
        agentPrompt: """
        Tu travailles dans le dossier du projet «{project}». Fichier source : {file}. \
        Lis tous les fichiers de ce dossier, mais n'en modifie aucun. Écris le résultat dans un nouveau fichier {output} dans le même dossier. \
        Si la tâche n'est pas claire ou s'il manque des données, dis-le au début du fichier de résultat — n'invente rien.

        Tâche : {task}
        """,
        agentNoFile: "aucun — travaille avec les fichiers du dossier",
        apiHeader: "Projet : «{project}». Format : {format}.",
        apiFileIntro: "Voici le texte du fichier «{file}».",
        apiTask: "Tâche : {task}",
        apiRule: "Réponds uniquement par le résultat en Markdown, sans introduction ni explication. S'il manque des données, dis-le en première ligne — n'invente rien.",
        nextStep: "Lis le README et, s'ils existent, docs/STATUS.md, CLAUDE.md ou AGENTS.md. Détermine la prochaine étape raisonnable : le premier point de la liste «Next / Ensuite» s'il existe, sinon la tâche inachevée la plus évidente. Fais-la dans une branche séparée de la branche principale : les modifications, les vérifications du projet (tests, build, linter — ce qui existe), un commit au message clair, un push et une pull request. Si l'étape demande la décision d'une personne ou n'est pas claire, ne modifie rien et décris brièvement la question.",
        customTask: "Tâche : {task}. Suis les règles du projet (CLAUDE.md / AGENTS.md s'ils existent) : une branche séparée de la branche principale, les vérifications du projet, commit, push, pull request.",
        finishSession: "Termine le travail en cours dans ce dossier : lance les vérifications du projet, répartis les modifications non commitées en commits par sujet (sur des branches séparées si elles relèvent de tâches différentes), fais un push et ouvre une pull request. Ne fais aucune nouvelle modification de code.",
        taskPrefix: "Tâche : ", rulesMarker: ". Suis les règles"
    )

    static let german = ContentStrings(
        cardFile: "projekt.md", planFile: "inhaltsplan.md",
        cardLabels: [.stage: "Phase", .deadline: "Frist", .publish: "Veröffentlichung", .format: "Format", .mainFile: "Hauptdatei", .platform: "Plattform"],
        notesHeading: "## Notizen", planTitle: "# Inhaltsplan",
        planColumns: [.date: "Datum", .time: "Uhrzeit", .platform: "Plattform", .topic: "Thema", .status: "Status", .file: "Datei"],
        ideaStatus: "Idee", notSet: "nicht angegeben", notCounted: "nicht berechnet", projectWord: "projekt", resultWord: "ergebnis",
        agentPrompt: """
        Du arbeitest im Ordner des Projekts «{project}». Quelldatei: {file}. \
        Lies beliebige Dateien dieses Ordners, ändere aber keine davon. Schreibe das Ergebnis in eine neue Datei {output} im selben Ordner. \
        Wenn die Aufgabe unklar ist oder Daten fehlen, schreibe das an den Anfang der Ergebnisdatei — erfinde nichts.
        
        Aufgabe: {task}
        """,
        agentNoFile: "keine — arbeite mit den Dateien des Ordners",
        apiHeader: "Projekt: «{project}». Format: {format}.",
        apiFileIntro: "Unten steht der Text der Datei «{file}».",
        apiTask: "Aufgabe: {task}",
        apiRule: "Antworte nur mit dem Ergebnis in Markdown, ohne Einleitung und Erklärungen. Wenn Daten fehlen, sag das in der ersten Zeile — erfinde nichts.",
        nextStep: "Lies die README und, falls vorhanden, docs/STATUS.md, CLAUDE.md oder AGENTS.md. Bestimme den nächsten sinnvollen Schritt: den ersten Punkt der Liste «Next / Als Nächstes», falls es sie gibt, sonst die offensichtlichste unerledigte Aufgabe. Erledige ihn in einem eigenen Branch vom Hauptbranch: die Änderungen, die Prüfungen des Projekts (Tests, Build, Linter — was vorhanden ist), ein Commit mit klarer Nachricht, Push und ein Pull Request. Wenn der Schritt die Entscheidung eines Menschen braucht oder unklar ist, ändere nichts und beschreibe die Frage kurz.",
        customTask: "Aufgabe: {task}. Halte dich an die Regeln des Projekts (CLAUDE.md / AGENTS.md, falls vorhanden): ein eigener Branch vom Hauptbranch, die Prüfungen des Projekts, Commit, Push, Pull Request.",
        finishSession: "Bringe die aktuelle Arbeit in diesem Ordner zu Ende: führe die Prüfungen des Projekts aus, teile nicht committete Änderungen nach Sinn in Commits auf (auf getrennte Branches, wenn sie zu verschiedenen Aufgaben gehören), pushe und öffne einen Pull Request. Nimm keine neuen Codeänderungen vor.",
        taskPrefix: "Aufgabe: ", rulesMarker: ". Halte dich an die Regeln"
    )

    static let japanese = ContentStrings(
        cardFile: "プロジェクト.md", planFile: "コンテンツ計画.md",
        cardLabels: [.stage: "段階", .deadline: "締め切り", .publish: "公開", .format: "形式", .mainFile: "メインファイル", .platform: "プラットフォーム"],
        notesHeading: "## メモ", planTitle: "# コンテンツ計画",
        planColumns: [.date: "日付", .time: "時刻", .platform: "プラットフォーム", .topic: "テーマ", .status: "状態", .file: "ファイル"],
        ideaStatus: "アイデア", notSet: "未指定", notCounted: "未計算", projectWord: "プロジェクト", resultWord: "結果",
        agentPrompt: """
        あなたはプロジェクト「{project}」のフォルダーで作業しています。元のファイル: {file}。\
        このフォルダーのファイルはどれを読んでもかまいませんが、どれも変更しないでください。結果は同じフォルダーの新しいファイル {output} に書いてください。\
        課題が不明確な場合やデータが足りない場合は、結果ファイルの冒頭にそう書いてください。推測で作らないでください。
        
        課題: {task}
        """,
        agentNoFile: "なし — フォルダー内のファイルで作業してください",
        apiHeader: "プロジェクト: 「{project}」。形式: {format}。",
        apiFileIntro: "以下はファイル「{file}」のテキストです。",
        apiTask: "課題: {task}",
        apiRule: "結果だけを Markdown で答えてください。前置きや説明は不要です。データが足りない場合は 1 行目にそう書き、推測で作らないでください。",
        nextStep: "README と、あれば docs/STATUS.md、CLAUDE.md または AGENTS.md を読んでください。次にやるべき妥当な一歩を決めてください。「Next / 次」リストがあればその最初の項目、なければ最も明らかな未完了のタスクです。メインから分けたブランチで行ってください: 変更、プロジェクトのチェック(テスト、ビルド、リンター — あるもの)、分かりやすいメッセージのコミット、push、pull request。人の判断が必要な場合や不明確な場合は何も変更せず、質問を短く書いてください。",
        customTask: "課題: {task}。プロジェクトのルール(あれば CLAUDE.md / AGENTS.md)に従ってください: メインから分けたブランチ、プロジェクトのチェック、コミット、push、pull request。",
        finishSession: "このフォルダーの現在の作業を仕上げてください: プロジェクトのチェックを実行し、未コミットの変更を意味ごとにコミットに分け(別のタスクのものは別ブランチに)、push して pull request を作成してください。新しいコード変更はしないでください。",
        taskPrefix: "課題: ", rulesMarker: "。プロジェクトのルール"
    )

    static let indonesian = ContentStrings(
        cardFile: "proyek.md", planFile: "rencana-konten.md",
        cardLabels: [.stage: "Tahap", .deadline: "Tenggat", .publish: "Publikasi", .format: "Format", .mainFile: "Berkas utama", .platform: "Platform"],
        notesHeading: "## Catatan", planTitle: "# Rencana konten",
        planColumns: [.date: "Tanggal", .time: "Jam", .platform: "Platform", .topic: "Topik", .status: "Status", .file: "Berkas"],
        ideaStatus: "ide", notSet: "tidak disebutkan", notCounted: "belum dihitung", projectWord: "proyek", resultWord: "hasil",
        agentPrompt: """
        Kamu bekerja di folder proyek «{project}». Berkas sumber: {file}. \
        Baca berkas apa pun di folder ini, tetapi jangan ubah satu pun. Tulis hasilnya ke berkas baru {output} di folder yang sama. \
        Jika tugas tidak jelas atau data kurang, tulis hal itu di awal berkas hasil — jangan mengarang.
        
        Tugas: {task}
        """,
        agentNoFile: "tidak ada — kerjakan dengan berkas di folder",
        apiHeader: "Proyek: «{project}». Format: {format}.",
        apiFileIntro: "Berikut teks berkas «{file}».",
        apiTask: "Tugas: {task}",
        apiRule: "Jawab hanya dengan hasilnya dalam Markdown, tanpa pembuka dan penjelasan. Jika data kurang, katakan di baris pertama — jangan mengarang.",
        nextStep: "Baca README dan, jika ada, docs/STATUS.md, CLAUDE.md, atau AGENTS.md. Tentukan langkah berikutnya yang masuk akal: butir pertama daftar «Next / Berikutnya» jika ada, jika tidak tugas belum selesai yang paling jelas. Kerjakan di branch terpisah dari branch utama: perubahan, pemeriksaan proyek (tes, build, linter — yang ada), commit dengan pesan yang jelas, push, dan pull request. Jika langkah itu butuh keputusan seseorang atau tidak jelas, jangan ubah apa pun dan jelaskan pertanyaannya secara singkat.",
        customTask: "Tugas: {task}. Ikuti aturan proyek (CLAUDE.md / AGENTS.md jika ada): branch terpisah dari branch utama, pemeriksaan proyek, commit, push, pull request.",
        finishSession: "Selesaikan pekerjaan yang sedang berjalan di folder ini: jalankan pemeriksaan proyek, bagi perubahan yang belum di-commit menjadi commit sesuai maknanya (ke branch terpisah jika milik tugas berbeda), push, dan buka pull request. Jangan membuat perubahan kode baru.",
        taskPrefix: "Tugas: ", rulesMarker: ". Ikuti aturan proyek"
    )

    static let korean = ContentStrings(
        cardFile: "프로젝트.md", planFile: "콘텐츠-계획.md",
        cardLabels: [.stage: "단계", .deadline: "마감", .publish: "게시", .format: "형식", .mainFile: "주요 파일", .platform: "플랫폼"],
        notesHeading: "## 메모", planTitle: "# 콘텐츠 계획",
        planColumns: [.date: "날짜", .time: "시간", .platform: "플랫폼", .topic: "주제", .status: "상태", .file: "파일"],
        ideaStatus: "아이디어", notSet: "지정 안 됨", notCounted: "계산 안 됨", projectWord: "프로젝트", resultWord: "결과",
        agentPrompt: """
        당신은 프로젝트 «{project}» 폴더에서 작업하고 있습니다. 원본 파일: {file}. \
        이 폴더의 파일은 무엇이든 읽어도 되지만 아무것도 수정하지 마세요. 결과는 같은 폴더의 새 파일 {output}에 쓰세요. \
        과제가 불분명하거나 데이터가 부족하면 결과 파일 맨 앞에 그렇게 적고, 지어내지 마세요.
        
        과제: {task}
        """,
        agentNoFile: "없음 — 폴더의 파일로 작업하세요",
        apiHeader: "프로젝트: «{project}». 형식: {format}.",
        apiFileIntro: "아래는 파일 «{file}»의 텍스트입니다.",
        apiTask: "과제: {task}",
        apiRule: "결과만 Markdown으로 답하세요. 서론이나 설명은 빼세요. 데이터가 부족하면 첫 줄에 그렇게 쓰고, 지어내지 마세요.",
        nextStep: "README와, 있다면 docs/STATUS.md, CLAUDE.md 또는 AGENTS.md를 읽으세요. 다음으로 할 합리적인 단계를 정하세요: «Next / 다음» 목록이 있으면 그 첫 항목, 없으면 가장 분명한 미완료 작업입니다. 메인과 분리된 브랜치에서 하세요: 변경, 프로젝트 검사(테스트, 빌드, 린터 — 있는 것), 명확한 메시지의 커밋, push, pull request. 사람의 결정이 필요하거나 불분명하면 아무것도 바꾸지 말고 질문을 짧게 적으세요.",
        customTask: "과제: {task}. 프로젝트 규칙(있다면 CLAUDE.md / AGENTS.md)을 따르세요: 메인과 분리된 브랜치, 프로젝트 검사, 커밋, push, pull request.",
        finishSession: "이 폴더의 현재 작업을 마무리하세요: 프로젝트 검사를 실행하고, 커밋되지 않은 변경을 의미별로 커밋으로 나누고(다른 작업이면 별도 브랜치로), push하고 pull request를 여세요. 새 코드 변경은 하지 마세요.",
        taskPrefix: "과제: ", rulesMarker: ". 프로젝트 규칙"
    )

    static let italian = ContentStrings(
        cardFile: "progetto.md", planFile: "piano-contenuti.md",
        cardLabels: [.stage: "Fase", .deadline: "Scadenza", .publish: "Pubblicazione", .format: "Formato", .mainFile: "File principale", .platform: "Piattaforma"],
        notesHeading: "## Note", planTitle: "# Piano dei contenuti",
        planColumns: [.date: "Data", .time: "Ora", .platform: "Piattaforma", .topic: "Tema", .status: "Stato", .file: "File"],
        ideaStatus: "idea", notSet: "non indicato", notCounted: "non calcolato", projectWord: "progetto", resultWord: "risultato",
        agentPrompt: """
        Stai lavorando nella cartella del progetto «{project}». File di partenza: {file}. \
        Leggi qualsiasi file di questa cartella, ma non modificarne nessuno. Scrivi il risultato in un nuovo file {output} nella stessa cartella. \
        Se il compito non è chiaro o mancano dati, scrivilo all'inizio del file di risultato — non inventare.
        
        Compito: {task}
        """,
        agentNoFile: "nessuno — lavora con i file della cartella",
        apiHeader: "Progetto: «{project}». Formato: {format}.",
        apiFileIntro: "Di seguito il testo del file «{file}».",
        apiTask: "Compito: {task}",
        apiRule: "Rispondi solo con il risultato in Markdown, senza introduzioni né spiegazioni. Se mancano dati, dillo nella prima riga — non inventare.",
        nextStep: "Leggi il README e, se esistono, docs/STATUS.md, CLAUDE.md o AGENTS.md. Individua il prossimo passo sensato: il primo punto dell'elenco «Next / Prossimo», se c'è, altrimenti il compito incompiuto più evidente. Fallo in un branch separato da quello principale: le modifiche, i controlli del progetto (test, build, linter — quello che c'è), un commit con un messaggio chiaro, push e una pull request. Se il passo richiede la decisione di una persona o non è chiaro, non modificare nulla e descrivi brevemente la domanda.",
        customTask: "Compito: {task}. Segui le regole del progetto (CLAUDE.md / AGENTS.md se presenti): un branch separato da quello principale, i controlli del progetto, commit, push, pull request.",
        finishSession: "Porta a termine il lavoro in corso in questa cartella: esegui i controlli del progetto, dividi le modifiche non committate in commit per argomento (su branch separati se riguardano compiti diversi), fai push e apri una pull request. Non fare nuove modifiche al codice.",
        taskPrefix: "Compito: ", rulesMarker: ". Segui le regole"
    )

    static let arabic = ContentStrings(
        cardFile: "مشروع.md", planFile: "خطة-المحتوى.md",
        cardLabels: [.stage: "المرحلة", .deadline: "الموعد النهائي", .publish: "النشر", .format: "الصيغة", .mainFile: "الملف الرئيسي", .platform: "المنصة"],
        notesHeading: "## ملاحظات", planTitle: "# خطة المحتوى",
        planColumns: [.date: "التاريخ", .time: "الوقت", .platform: "المنصة", .topic: "الموضوع", .status: "الحالة", .file: "الملف"],
        ideaStatus: "فكرة", notSet: "غير محدد", notCounted: "غير محسوب", projectWord: "مشروع", resultWord: "نتيجة",
        agentPrompt: """
        أنت تعمل في مجلد المشروع «{project}». الملف المصدر: {file}. \
        اقرأ أي ملف في هذا المجلد، لكن لا تعدّل أيًّا منها. اكتب النتيجة في ملف جديد {output} في المجلد نفسه. \
        إذا كانت المهمة غير واضحة أو كانت البيانات ناقصة، فاذكر ذلك في بداية ملف النتيجة — ولا تختلق شيئًا.
        
        المهمة: {task}
        """,
        agentNoFile: "لا يوجد — اعمل على ملفات المجلد",
        apiHeader: "المشروع: «{project}». الصيغة: {format}.",
        apiFileIntro: "فيما يلي نص الملف «{file}».",
        apiTask: "المهمة: {task}",
        apiRule: "أجب بالنتيجة فقط بصيغة Markdown، دون مقدمات أو شروح. إذا كانت البيانات ناقصة فاذكر ذلك في السطر الأول — ولا تختلق شيئًا.",
        nextStep: "اقرأ ملف README، وكذلك docs/STATUS.md أو CLAUDE.md أو AGENTS.md إن وُجدت. حدّد الخطوة التالية المعقولة: البند الأول من قائمة «Next / التالي» إن وُجدت، وإلا فالمهمة غير المكتملة الأوضح. نفّذها في فرع منفصل عن الفرع الرئيسي: التغييرات، وفحوصات المشروع (الاختبارات، البناء، أداة الفحص — ما يتوفر منها)، و commit برسالة واضحة، و push، و pull request. إذا احتاجت الخطوة إلى قرار من شخص أو كانت غير واضحة، فلا تغيّر شيئًا وصِف السؤال باختصار.",
        customTask: "المهمة: {task}. اتبع قواعد المشروع (CLAUDE.md / AGENTS.md إن وُجدت): فرع منفصل عن الفرع الرئيسي، وفحوصات المشروع، و commit، و push، و pull request.",
        finishSession: "أكمل العمل الجاري في هذا المجلد: شغّل فحوصات المشروع، وقسّم التغييرات غير المحفوظة في commits حسب معناها (في فروع منفصلة إن كانت لمهام مختلفة)، ثم نفّذ push وافتح pull request. لا تُجرِ أي تغييرات جديدة على الشيفرة.",
        taskPrefix: "المهمة: ", rulesMarker: ". اتبع قواعد المشروع"
    )

    static let polish = ContentStrings(
        cardFile: "projekt.md", planFile: "plan-tresci.md",
        cardLabels: [.stage: "Etap", .deadline: "Termin", .publish: "Publikacja", .format: "Format", .mainFile: "Plik główny", .platform: "Platforma"],
        notesHeading: "## Notatki", planTitle: "# Plan treści",
        planColumns: [.date: "Data", .time: "Godzina", .platform: "Platforma", .topic: "Temat", .status: "Status", .file: "Plik"],
        ideaStatus: "pomysł", notSet: "nie podano", notCounted: "nie obliczono", projectWord: "projekt", resultWord: "wynik",
        agentPrompt: """
        Pracujesz w folderze projektu «{project}». Plik źródłowy: {file}. \
        Czytaj dowolne pliki tego folderu, ale żadnego nie zmieniaj. Zapisz wynik w nowym pliku {output} w tym samym folderze. \
        Jeśli zadanie jest niejasne lub brakuje danych, napisz o tym na początku pliku wynikowego — niczego nie wymyślaj.
        
        Zadanie: {task}
        """,
        agentNoFile: "brak — pracuj na plikach folderu",
        apiHeader: "Projekt: «{project}». Format: {format}.",
        apiFileIntro: "Poniżej tekst pliku «{file}».",
        apiTask: "Zadanie: {task}",
        apiRule: "Odpowiedz tylko wynikiem w Markdown, bez wstępów i wyjaśnień. Jeśli brakuje danych, napisz o tym w pierwszej linii — niczego nie wymyślaj.",
        nextStep: "Przeczytaj README oraz, jeśli istnieją, docs/STATUS.md, CLAUDE.md lub AGENTS.md. Ustal następny rozsądny krok: pierwszy punkt listy «Next / Dalej», jeśli jest, a jeśli nie — najbardziej oczywiste niedokończone zadanie. Wykonaj go w osobnej gałęzi od głównej: zmiany, kontrole projektu (testy, build, linter — co jest), commit z jasnym opisem, push i pull request. Jeśli krok wymaga decyzji człowieka lub jest niejasny, niczego nie zmieniaj i krótko opisz pytanie.",
        customTask: "Zadanie: {task}. Przestrzegaj zasad projektu (CLAUDE.md / AGENTS.md, jeśli istnieją): osobna gałąź od głównej, kontrole projektu, commit, push, pull request.",
        finishSession: "Dokończ bieżącą pracę w tym folderze: uruchom kontrole projektu, podziel niezacommitowane zmiany na commity według sensu (na osobne gałęzie, jeśli dotyczą różnych zadań), zrób push i otwórz pull request. Nie wprowadzaj nowych zmian w kodzie.",
        taskPrefix: "Zadanie: ", rulesMarker: ". Przestrzegaj zasad"
    )

    static let ukrainian = ContentStrings(
        cardFile: "проєкт.md", planFile: "контент-план.md",
        cardLabels: [.stage: "Етап", .deadline: "Дедлайн", .publish: "Публікація", .format: "Формат", .mainFile: "Головний файл", .platform: "Майданчик"],
        notesHeading: "## Нотатки", planTitle: "# Контент-план",
        planColumns: [.date: "Дата", .time: "Час", .platform: "Майданчик", .topic: "Тема", .status: "Статус", .file: "Файл"],
        ideaStatus: "ідея", notSet: "не вказано", notCounted: "не пораховано", projectWord: "проєкт", resultWord: "результат",
        agentPrompt: """
        Ти працюєш у папці проєкту «{project}». Вихідний файл: {file}. \
        Читай будь-які файли цієї папки, але нічого в них не змінюй. Результат запиши в новий файл {output} у цій самій папці. \
        Якщо завдання незрозуміле або бракує даних — напиши про це на початку файлу результату, не вигадуй.
        
        Завдання: {task}
        """,
        agentNoFile: "немає — працюй з файлами папки",
        apiHeader: "Проєкт: «{project}». Формат: {format}.",
        apiFileIntro: "Нижче — текст файлу «{file}».",
        apiTask: "Завдання: {task}",
        apiRule: "Відповідай лише результатом у Markdown, без вступів і пояснень. Якщо бракує даних — скажи про це першим рядком, не вигадуй.",
        nextStep: "Прочитай README і, якщо є, docs/STATUS.md, CLAUDE.md або AGENTS.md. Визнач наступний розумний крок: перший пункт списку «Next / Далі», якщо він є, інакше найочевидніше незавершене завдання. Зроби його в окремій гілці від основної: зміни, перевірки проєкту (тести, збірка, лінтер — що є), коміт зі зрозумілим повідомленням, push і pull request. Якщо крок потребує рішення людини або незрозумілий — нічого не змінюй, а коротко опиши питання.",
        customTask: "Завдання: {task}. Працюй за правилами проєкту (CLAUDE.md / AGENTS.md, якщо вони є): окрема гілка від основної, перевірки проєкту, коміт, push, pull request.",
        finishSession: "Доведи до кінця поточну роботу в цій папці: запусти перевірки проєкту, розклади незакомічені зміни за змістом на коміти (якщо вони стосуються різних завдань — по окремих гілках), зроби push і pull request. Нових змін коду не роби.",
        taskPrefix: "Завдання: ", rulesMarker: ". Працюй за правилами"
    )

    /// `{name}` → value, for the templates above.
    static func fill(_ text: String, _ values: [String: String]) -> String {
        values.reduce(text) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
    }
}
