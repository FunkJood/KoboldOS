import SwiftUI
import Foundation

// MARK: - App Language (15 languages)

public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case german     = "de"
    case english    = "en"
    case french     = "fr"
    case spanish    = "es"
    case italian    = "it"
    case portuguese = "pt"
    case hindi      = "hi"
    case chinese    = "zh"
    case japanese   = "ja"
    case korean     = "ko"
    case turkish    = "tr"
    case polish     = "pl"
    case dutch      = "nl"
    case arabic     = "ar"
    case russian    = "ru"

    public var displayName: String {
        switch self {
        case .german:     return "🇩🇪 Deutsch"
        case .english:    return "🇬🇧 English"
        case .french:     return "🇫🇷 Français"
        case .spanish:    return "🇪🇸 Español"
        case .italian:    return "🇮🇹 Italiano"
        case .portuguese: return "🇵🇹 Português"
        case .hindi:      return "🇮🇳 हिन्दी"
        case .chinese:    return "🇨🇳 中文"
        case .japanese:   return "🇯🇵 日本語"
        case .korean:     return "🇰🇷 한국어"
        case .turkish:    return "🇹🇷 Türkçe"
        case .polish:     return "🇵🇱 Polski"
        case .dutch:      return "🇳🇱 Nederlands"
        case .arabic:     return "🇸🇦 العربية"
        case .russian:    return "🇷🇺 Русский"
        }
    }

    /// Injected into every agent system prompt
    public var agentInstruction: String {
        switch self {
        case .german:     return "Antworte immer auf Deutsch. Kommuniziere ausschließlich auf Deutsch."
        case .english:    return "Always respond in English."
        case .french:     return "Réponds toujours en français."
        case .spanish:    return "Responde siempre en español."
        case .italian:    return "Rispondi sempre in italiano."
        case .portuguese: return "Responda sempre em português."
        case .hindi:      return "हमेशा हिंदी में जवाब दें।"
        case .chinese:    return "请始终用中文回答。"
        case .japanese:   return "常に日本語で回答してください。"
        case .korean:     return "항상 한국어로 답변해 주세요."
        case .turkish:    return "Her zaman Türkçe yanıt verin."
        case .polish:     return "Zawsze odpowiadaj po polsku."
        case .dutch:      return "Antwoord altijd in het Nederlands."
        case .arabic:     return "أجب دائماً باللغة العربية."
        case .russian:    return "Всегда отвечайте на русском языке."
        }
    }

    // MARK: - Dictionary-Based Translation Lookup

    private static let t: [String: [AppLanguage: String]] = [
        // Navigation
        "chat":       [.german: "Chat", .english: "Chat", .french: "Chat", .spanish: "Chat", .italian: "Chat", .portuguese: "Chat", .hindi: "चैट", .chinese: "聊天", .japanese: "チャット", .korean: "채팅", .turkish: "Sohbet", .polish: "Czat", .dutch: "Chat", .arabic: "محادثة", .russian: "Чат"],
        "dashboard":  [.german: "Dashboard", .english: "Dashboard", .french: "Dashboard", .spanish: "Panel", .italian: "Pannello", .portuguese: "Painel", .hindi: "डैशबोर्ड", .chinese: "仪表盘", .japanese: "ダッシュボード", .korean: "대시보드", .turkish: "Panel", .polish: "Panel", .dutch: "Dashboard", .arabic: "لوحة القيادة", .russian: "Панель"],
        "memory":     [.german: "Speicher", .english: "Memory", .french: "Mémoire", .spanish: "Memoria", .italian: "Memoria", .portuguese: "Memória", .hindi: "स्मृति", .chinese: "记忆", .japanese: "メモリ", .korean: "메모리", .turkish: "Hafıza", .polish: "Pamięć", .dutch: "Geheugen", .arabic: "الذاكرة", .russian: "Память"],
        "tasks":      [.german: "Aufgaben", .english: "Tasks", .french: "Tâches", .spanish: "Tareas", .italian: "Compiti", .portuguese: "Tarefas", .hindi: "कार्य", .chinese: "任务", .japanese: "タスク", .korean: "작업", .turkish: "Görevler", .polish: "Zadania", .dutch: "Taken", .arabic: "المهام", .russian: "Задачи"],
        "models":     [.german: "Modelle", .english: "Models", .french: "Modèles", .spanish: "Modelos", .italian: "Modelli", .portuguese: "Modelos", .hindi: "मॉडल", .chinese: "模型", .japanese: "モデル", .korean: "모델", .turkish: "Modeller", .polish: "Modele", .dutch: "Modellen", .arabic: "النماذج", .russian: "Модели"],
        "team":       [.german: "Workflows", .english: "Workflows", .french: "Workflows", .spanish: "Workflows", .italian: "Workflows", .portuguese: "Workflows", .hindi: "वर्कफ़्लो", .chinese: "工作流", .japanese: "ワークフロー", .korean: "워크플로", .turkish: "İş Akışları", .polish: "Przepływy", .dutch: "Workflows", .arabic: "سير العمل", .russian: "Рабочие процессы"],
        "agents":     [.german: "Agenten", .english: "Agents", .french: "Agents", .spanish: "Agentes", .italian: "Agenti", .portuguese: "Agentes", .hindi: "एजेंट", .chinese: "代理", .japanese: "エージェント", .korean: "에이전트", .turkish: "Ajanlar", .polish: "Agenci", .dutch: "Agenten", .arabic: "الوكلاء", .russian: "Агенты"],
        "settings":   [.german: "Einstellungen", .english: "Settings", .french: "Paramètres", .spanish: "Ajustes", .italian: "Impostazioni", .portuguese: "Configurações", .hindi: "सेटिंग्स", .chinese: "设置", .japanese: "設定", .korean: "설정", .turkish: "Ayarlar", .polish: "Ustawienia", .dutch: "Instellingen", .arabic: "الإعدادات", .russian: "Настройки"],

        // Chat UI
        "connected":  [.german: "Verbunden", .english: "Connected", .french: "Connecté", .spanish: "Conectado", .italian: "Connesso", .portuguese: "Conectado", .hindi: "जुड़ा हुआ", .chinese: "已连接", .japanese: "接続済み", .korean: "연결됨", .turkish: "Bağlı", .polish: "Połączony", .dutch: "Verbonden", .arabic: "متصل", .russian: "Подключено"],
        "offline":    [.german: "Offline", .english: "Offline", .french: "Hors ligne", .spanish: "Sin conexión", .italian: "Offline", .portuguese: "Offline", .hindi: "ऑफ़लाइन", .chinese: "离线", .japanese: "オフライン", .korean: "오프라인", .turkish: "Çevrimdışı", .polish: "Offline", .dutch: "Offline", .arabic: "غير متصل", .russian: "Офлайн"],
        "clearHistory": [.german: "Verlauf leeren", .english: "Clear History", .french: "Effacer", .spanish: "Borrar", .italian: "Cancella", .portuguese: "Limpar", .hindi: "इतिहास साफ़ करें", .chinese: "清除历史", .japanese: "履歴をクリア", .korean: "기록 삭제", .turkish: "Geçmişi Temizle", .polish: "Wyczyść", .dutch: "Wis Geschiedenis", .arabic: "مسح السجل", .russian: "Очистить"],
        "typeMessage": [.german: "Nachricht eingeben...", .english: "Type a message...", .french: "Écrire...", .spanish: "Escribe...", .italian: "Scrivi...", .portuguese: "Escreva...", .hindi: "संदेश लिखें...", .chinese: "输入消息...", .japanese: "メッセージを入力...", .korean: "메시지 입력...", .turkish: "Mesaj yaz...", .polish: "Napisz...", .dutch: "Typ een bericht...", .arabic: "...اكتب رسالة", .russian: "Введите сообщение..."],
        "toolsAvailable": [.german: "Tools verfügbar — einfach tippen", .english: "Tools available — just type naturally", .french: "Outils disponibles", .spanish: "Herramientas disponibles", .italian: "Strumenti disponibili", .portuguese: "Ferramentas disponíveis", .hindi: "उपकरण उपलब्ध", .chinese: "工具可用", .japanese: "ツール利用可能", .korean: "도구 사용 가능", .turkish: "Araçlar mevcut", .polish: "Narzędzia dostępne", .dutch: "Tools beschikbaar", .arabic: "الأدوات متوفرة", .russian: "Инструменты доступны"],
        "startConversation": [.german: "Gespräch starten", .english: "Start a conversation", .french: "Démarrer une conversation", .spanish: "Iniciar conversación", .italian: "Inizia una conversazione", .portuguese: "Iniciar conversa", .hindi: "बातचीत शुरू करें", .chinese: "开始对话", .japanese: "会話を始める", .korean: "대화 시작", .turkish: "Sohbet Başlat", .polish: "Rozpocznij rozmowę", .dutch: "Start een gesprek", .arabic: "بدء محادثة", .russian: "Начать разговор"],
        "thinking":   [.german: "Denkt nach...", .english: "Thinking...", .french: "Réflexion...", .spanish: "Pensando...", .italian: "Pensando...", .portuguese: "Pensando...", .hindi: "सोच रहा है...", .chinese: "思考中...", .japanese: "考え中...", .korean: "생각 중...", .turkish: "Düşünüyor...", .polish: "Myśli...", .dutch: "Denkt na...", .arabic: "...يفكر", .russian: "Думает..."],

        // Onboarding
        "obContinue": [.german: "Weiter →", .english: "Continue →", .french: "Continuer →", .spanish: "Continuar →", .italian: "Continua →", .portuguese: "Continuar →", .hindi: "आगे →", .chinese: "继续 →", .japanese: "続ける →", .korean: "계속 →", .turkish: "Devam →", .polish: "Dalej →", .dutch: "Verder →", .arabic: "← متابعة", .russian: "Далее →"],
        "obBack": [.german: "Zurück", .english: "Back", .french: "Retour", .spanish: "Volver", .italian: "Indietro", .portuguese: "Voltar", .hindi: "वापस", .chinese: "返回", .japanese: "戻る", .korean: "뒤로", .turkish: "Geri", .polish: "Wstecz", .dutch: "Terug", .arabic: "رجوع", .russian: "Назад"],
        "obInstall": [.german: "Installieren", .english: "Install", .french: "Installer", .spanish: "Instalar", .italian: "Installa", .portuguese: "Instalar", .hindi: "इंस्टॉल", .chinese: "安装", .japanese: "インストール", .korean: "설치", .turkish: "Yükle", .polish: "Zainstaluj", .dutch: "Installeren", .arabic: "تثبيت", .russian: "Установить"],
        "obLetsGo": [.german: "Los geht's!", .english: "Let's Go!", .french: "C'est parti !", .spanish: "¡Vamos!", .italian: "Andiamo!", .portuguese: "Vamos!", .hindi: "चलो!", .chinese: "开始吧！", .japanese: "始めよう！", .korean: "시작!", .turkish: "Başlayalım!", .polish: "Zaczynamy!", .dutch: "Laten we gaan!", .arabic: "!هيا بنا", .russian: "Поехали!"],
        "obStartWith": [.german: "Los geht's mit", .english: "Let's go with", .french: "C'est parti avec", .spanish: "¡Vamos con", .italian: "Andiamo con", .portuguese: "Vamos com", .hindi: "शुरू करें", .chinese: "开始使用", .japanese: "始めましょう", .korean: "시작하기", .turkish: "Başlayalım:", .polish: "Zaczynamy z", .dutch: "Laten we beginnen met", .arabic: "هيا مع", .russian: "Начнём с"],
        "obBeginHatching": [.german: "Schlüpfen beginnen", .english: "Begin Hatching", .french: "Commencer l'éclosion", .spanish: "Comenzar a eclosionar", .italian: "Inizia la schiusa", .portuguese: "Começar a chocar", .hindi: "हैचिंग शुरू", .chinese: "开始孵化", .japanese: "孵化開始", .korean: "부화 시작", .turkish: "Kuluçkaya Başla", .polish: "Rozpocznij wylęg", .dutch: "Begin met uitbroeden", .arabic: "بدء الفقس", .russian: "Начать вылупление"],
        "obEggSubtitle": [.german: "Dein KI-Assistent wartet auf seine Geburt.", .english: "Your personal AI is waiting to be born.", .french: "Ton IA personnelle attend de naître.", .spanish: "Tu IA personal espera nacer.", .italian: "La tua IA personale aspetta di nascere.", .portuguese: "Sua IA pessoal está esperando para nascer.", .hindi: "आपका AI जन्म की प्रतीक्षा में है।", .chinese: "你的AI助手正在等待诞生。", .japanese: "あなたのAIアシスタントが誕生を待っています。", .korean: "당신의 AI 어시스턴트가 탄생을 기다리고 있습니다.", .turkish: "Kişisel yapay zekanız doğmayı bekliyor.", .polish: "Twój asystent AI czeka na narodziny.", .dutch: "Je persoonlijke AI wacht om geboren te worden.", .arabic: "مساعدك الذكي في انتظار الولادة.", .russian: "Ваш ИИ-ассистент ждёт рождения."],
        "obSomethingStirs": [.german: "Etwas regt sich...", .english: "Something stirs inside...", .french: "Quelque chose s'agite...", .spanish: "Algo se mueve...", .italian: "Qualcosa si agita...", .portuguese: "Algo se mexe...", .hindi: "कुछ हलचल हो रही है...", .chinese: "有什么在动...", .japanese: "何かが動いている...", .korean: "무언가 움직이고 있어요...", .turkish: "Bir şeyler kıpırdıyor...", .polish: "Coś się rusza...", .dutch: "Er beweegt iets...", .arabic: "...شيء يتحرك", .russian: "Что-то шевелится..."],
        "obNameTitle": [.german: "Wie heißt du?", .english: "What's your name?", .french: "Comment t'appelles-tu ?", .spanish: "¿Cómo te llamas?", .italian: "Come ti chiami?", .portuguese: "Qual é o seu nome?", .hindi: "आपका नाम क्या है?", .chinese: "你叫什么名字？", .japanese: "お名前は？", .korean: "이름이 뭐예요?", .turkish: "Adınız ne?", .polish: "Jak masz na imię?", .dutch: "Wat is je naam?", .arabic: "ما اسمك؟", .russian: "Как вас зовут?"],
        "obNameSubtitle": [.german: "Dein Kobold wird sich an dich erinnern.", .english: "Your Kobold will remember you.", .french: "Ton Kobold se souviendra de toi.", .spanish: "Tu Kobold te recordará.", .italian: "Il tuo Kobold ti ricorderà.", .portuguese: "Seu Kobold vai lembrar de você.", .hindi: "आपका कोबोल्ड आपको याद रखेगा।", .chinese: "你的Kobold会记住你。", .japanese: "あなたのKoboldはあなたを覚えます。", .korean: "당신의 Kobold가 당신을 기억할 거예요.", .turkish: "Kobold'unuz sizi hatırlayacak.", .polish: "Twój Kobold cię zapamięta.", .dutch: "Je Kobold zal je onthouden.", .arabic: "سيتذكرك الكوبولد.", .russian: "Ваш Kobold будет помнить вас."],
        "obNamePlaceholder": [.german: "Deinen Namen eingeben...", .english: "Enter your name...", .french: "Entrez votre nom...", .spanish: "Ingresa tu nombre...", .italian: "Inserisci il tuo nome...", .portuguese: "Digite seu nome...", .hindi: "अपना नाम दर्ज करें...", .chinese: "输入你的名字...", .japanese: "名前を入力...", .korean: "이름을 입력하세요...", .turkish: "Adınızı girin...", .polish: "Wpisz swoje imię...", .dutch: "Voer je naam in...", .arabic: "...أدخل اسمك", .russian: "Введите имя..."],
        "obKoboldNamePrompt": [.german: "Und wie soll dein Kobold heißen?", .english: "What should your Kobold be called?", .french: "Comment s'appellera ton Kobold ?", .spanish: "¿Cómo se llamará tu Kobold?", .italian: "Come si chiamerà il tuo Kobold?", .portuguese: "Como seu Kobold se chamará?", .hindi: "आपके कोबोल्ड का नाम क्या होगा?", .chinese: "你的Kobold叫什么名字？", .japanese: "Koboldの名前は？", .korean: "Kobold의 이름은?", .turkish: "Kobold'unuzun adı ne olsun?", .polish: "Jak będzie się nazywał twój Kobold?", .dutch: "Hoe moet je Kobold heten?", .arabic: "ماذا سيكون اسم الكوبولد؟", .russian: "Как назвать вашего Kobold?"],
        "obKoboldNamePlaceholder": [.german: "Kobold-Name (Standard: Kobold)", .english: "Kobold's name (default: Kobold)", .french: "Nom du Kobold (défaut: Kobold)", .spanish: "Nombre del Kobold (por defecto: Kobold)", .italian: "Nome del Kobold (default: Kobold)", .portuguese: "Nome do Kobold (padrão: Kobold)", .hindi: "कोबोल्ड का नाम (डिफ़ॉल्ट: Kobold)", .chinese: "Kobold名称（默认：Kobold）", .japanese: "Kobold名（デフォルト：Kobold）", .korean: "Kobold 이름 (기본: Kobold)", .turkish: "Kobold adı (varsayılan: Kobold)", .polish: "Nazwa Kobolda (domyślnie: Kobold)", .dutch: "Kobold naam (standaard: Kobold)", .arabic: "(Kobold :افتراضي) اسم الكوبولد", .russian: "Имя Kobold (по умолчанию: Kobold)"],
        "obPersonalityTitle": [.german: "Persönlichkeit wählen", .english: "Choose a Personality", .french: "Choisir une personnalité", .spanish: "Elige una personalidad", .italian: "Scegli una personalità", .portuguese: "Escolha uma personalidade", .hindi: "व्यक्तित्व चुनें", .chinese: "选择性格", .japanese: "性格を選ぶ", .korean: "성격 선택", .turkish: "Kişilik Seçin", .polish: "Wybierz osobowość", .dutch: "Kies een persoonlijkheid", .arabic: "اختر شخصية", .russian: "Выберите характер"],
        "obPersonalitySubtitle": [.german: "So denkt und antwortet dein Kobold.", .english: "This shapes how your Kobold thinks and responds.", .french: "Cela façonne la pensée de ton Kobold.", .spanish: "Esto determina cómo piensa tu Kobold.", .italian: "Questo determina come pensa il tuo Kobold.", .portuguese: "Isso define como seu Kobold pensa.", .hindi: "यह तय करता है कि आपका कोबोल्ड कैसे सोचता है।", .chinese: "这决定了你的Kobold如何思考。", .japanese: "Koboldの思考方法を決めます。", .korean: "Kobold의 사고방식을 결정합니다.", .turkish: "Kobold'unuzun düşünme şeklini belirler.", .polish: "To kształtuje sposób myślenia Kobolda.", .dutch: "Dit bepaalt hoe je Kobold denkt.", .arabic: "هذا يحدد كيف يفكر الكوبولد.", .russian: "Это определяет, как ваш Kobold думает."],
        "obUseTitle": [.german: "Hauptverwendung", .english: "Primary Use", .french: "Usage principal", .spanish: "Uso principal", .italian: "Uso principale", .portuguese: "Uso principal", .hindi: "मुख्य उपयोग", .chinese: "主要用途", .japanese: "主な用途", .korean: "주요 용도", .turkish: "Ana Kullanım", .polish: "Główne zastosowanie", .dutch: "Primair gebruik", .arabic: "الاستخدام الرئيسي", .russian: "Основное применение"],
        "obUseSubtitle": [.german: "Wofür wirst du ihn hauptsächlich einsetzen?", .english: "What will you use it for most?", .french: "Pour quoi l'utiliser le plus ?", .spanish: "¿Para qué lo usarás principalmente?", .italian: "Per cosa lo userai principalmente?", .portuguese: "Para que você mais usará?", .hindi: "आप इसे मुख्य रूप से किसलिए इस्तेमाल करेंगे?", .chinese: "你主要用来做什么？", .japanese: "主に何に使いますか？", .korean: "주로 무엇에 사용하시겠어요?", .turkish: "En çok ne için kullanacaksınız?", .polish: "Do czego będziesz go głównie używać?", .dutch: "Waar ga je het het meest voor gebruiken?", .arabic: "فيم ستستخدمه بشكل أساسي؟", .russian: "Для чего в основном будете использовать?"],
        "obHatch": [.german: "Schlüpfen!", .english: "Hatch!", .french: "Éclore !", .spanish: "¡Eclosionar!", .italian: "Schiudi!", .portuguese: "Chocar!", .hindi: "हैच!", .chinese: "孵化！", .japanese: "孵化！", .korean: "부화!", .turkish: "Çık!", .polish: "Wylęg!", .dutch: "Uitbroeden!", .arabic: "!فقس", .russian: "Вылупиться!"],
        "obHatching": [.german: "Schlüpft...", .english: "Hatching...", .french: "Éclosion...", .spanish: "Eclosionando...", .italian: "Schiudendo...", .portuguese: "Chocando...", .hindi: "हैचिंग...", .chinese: "孵化中...", .japanese: "孵化中...", .korean: "부화 중...", .turkish: "Kuluçka...", .polish: "Wylęg...", .dutch: "Uitbroeden...", .arabic: "...يفقس", .russian: "Вылупляется..."],
        "obSettingUp": [.german: "Richte ein...", .english: "Setting up...", .french: "Configuration...", .spanish: "Configurando...", .italian: "Configurando...", .portuguese: "Configurando...", .hindi: "सेटअप हो रहा है...", .chinese: "正在设置...", .japanese: "設定中...", .korean: "설정 중...", .turkish: "Ayarlanıyor...", .polish: "Konfiguracja...", .dutch: "Instellen...", .arabic: "...جارٍ الإعداد", .russian: "Настройка..."],
        "obLoadingMemory": [.german: "Lade Erinnerungen...", .english: "Loading memory...", .french: "Chargement de la mémoire...", .spanish: "Cargando memoria...", .italian: "Caricamento memoria...", .portuguese: "Carregando memória...", .hindi: "मेमोरी लोड हो रही है...", .chinese: "加载记忆...", .japanese: "メモリ読み込み中...", .korean: "메모리 로딩...", .turkish: "Hafıza yükleniyor...", .polish: "Ładowanie pamięci...", .dutch: "Geheugen laden...", .arabic: "...تحميل الذاكرة", .russian: "Загрузка памяти..."],
        "obWakingUp": [.german: "Wecke auf...", .english: "Waking up...", .french: "Réveil en cours...", .spanish: "Despertando...", .italian: "Svegliando...", .portuguese: "Acordando...", .hindi: "जागा रहा है...", .chinese: "正在唤醒...", .japanese: "起動中...", .korean: "깨우는 중...", .turkish: "Uyanıyor...", .polish: "Budzi się...", .dutch: "Wakker worden...", .arabic: "...يستيقظ", .russian: "Просыпается..."],
        "obInstallOllama": [.german: "Ollama installieren?", .english: "Install Ollama?", .french: "Installer Ollama ?", .spanish: "¿Instalar Ollama?", .italian: "Installare Ollama?", .portuguese: "Instalar Ollama?", .hindi: "Ollama इंस्टॉल करें?", .chinese: "安装Ollama？", .japanese: "Ollamaをインストール？", .korean: "Ollama 설치?", .turkish: "Ollama yüklensin mi?", .polish: "Zainstalować Ollama?", .dutch: "Ollama installeren?", .arabic: "تثبيت Ollama؟", .russian: "Установить Ollama?"],
        "obOllamaInstalled": [.german: "Ollama installiert ✓", .english: "Ollama installed ✓", .french: "Ollama installé ✓", .spanish: "Ollama instalado ✓", .italian: "Ollama installato ✓", .portuguese: "Ollama instalado ✓", .hindi: "Ollama इंस्टॉल ✓", .chinese: "Ollama 已安装 ✓", .japanese: "Ollama インストール済 ✓", .korean: "Ollama 설치됨 ✓", .turkish: "Ollama yüklü ✓", .polish: "Ollama zainstalowany ✓", .dutch: "Ollama geïnstalleerd ✓", .arabic: "✓ Ollama مثبت", .russian: "Ollama установлен ✓"],
        "obOllamaDesc": [.german: "Ollama stellt lokale KI-Modelle bereit (benötigt).", .english: "Ollama provides local AI models (required).", .french: "Ollama fournit des modèles IA locaux (requis).", .spanish: "Ollama proporciona modelos de IA locales (requerido).", .italian: "Ollama fornisce modelli AI locali (necessario).", .portuguese: "Ollama fornece modelos de IA locais (necessário).", .hindi: "Ollama स्थानीय AI मॉडल प्रदान करता है (आवश्यक)।", .chinese: "Ollama提供本地AI模型（必需）。", .japanese: "Ollamaはローカルの AI モデルを提供します（必須）。", .korean: "Ollama는 로컬 AI 모델을 제공합니다(필수).", .turkish: "Ollama yerel yapay zeka modelleri sağlar (gerekli).", .polish: "Ollama dostarcza lokalne modele AI (wymagane).", .dutch: "Ollama levert lokale AI-modellen (vereist).", .arabic: "Ollama يوفر نماذج ذكاء اصطناعي محلية (مطلوب).", .russian: "Ollama предоставляет локальные ИИ-модели (обязательно)."],
        "obLanguagePrompt": [.german: "Wähle deine Sprache", .english: "Choose your language", .french: "Choisis ta langue", .spanish: "Elige tu idioma", .italian: "Scegli la tua lingua", .portuguese: "Escolha seu idioma", .hindi: "अपनी भाषा चुनें", .chinese: "选择你的语言", .japanese: "言語を選んでください", .korean: "언어를 선택하세요", .turkish: "Dilini seç", .polish: "Wybierz język", .dutch: "Kies je taal", .arabic: "اختر لغتك", .russian: "Выберите язык"],
        "obLanguagePicker": [.german: "Sprache", .english: "Language", .french: "Langue", .spanish: "Idioma", .italian: "Lingua", .portuguese: "Idioma", .hindi: "भाषा", .chinese: "语言", .japanese: "言語", .korean: "언어", .turkish: "Dil", .polish: "Język", .dutch: "Taal", .arabic: "اللغة", .russian: "Язык"],
        "obModelsTitle": [.german: "Modelle herunterladen", .english: "Download Models", .french: "Télécharger les modèles", .spanish: "Descargar modelos", .italian: "Scarica modelli", .portuguese: "Baixar modelos", .hindi: "मॉडल डाउनलोड करें", .chinese: "下载模型", .japanese: "モデルをダウンロード", .korean: "모델 다운로드", .turkish: "Modelleri İndir", .polish: "Pobierz modele", .dutch: "Modellen downloaden", .arabic: "تحميل النماذج", .russian: "Скачать модели"],
        "obModelsSubtitle": [.german: "Lade das KI-Modell für den Chat.", .english: "Download the AI model for chat.", .french: "Télécharge le modèle IA pour le chat.", .spanish: "Descarga el modelo de IA para el chat.", .italian: "Scarica il modello AI per la chat.", .portuguese: "Baixe o modelo de IA para o chat.", .hindi: "चैट के लिए AI मॉडल डाउनलोड करें।", .chinese: "下载用于聊天的AI模型。", .japanese: "チャット用のAIモデルをダウンロードします。", .korean: "채팅용 AI 모델을 다운로드하세요.", .turkish: "Sohbet için yapay zeka modelini indirin.", .polish: "Pobierz model AI do czatu.", .dutch: "Download het AI-model voor chat.", .arabic: "حمّل نموذج الذكاء الاصطناعي للمحادثة.", .russian: "Скачайте ИИ-модель для чата."],
        "obChatModel": [.german: "Chat-Modell", .english: "Chat Model", .french: "Modèle de chat", .spanish: "Modelo de chat", .italian: "Modello chat", .portuguese: "Modelo de chat", .hindi: "चैट मॉडल", .chinese: "聊天模型", .japanese: "チャットモデル", .korean: "채팅 모델", .turkish: "Sohbet Modeli", .polish: "Model czatu", .dutch: "Chatmodel", .arabic: "نموذج المحادثة", .russian: "Модель чата"],
        "obAlreadyInstalled": [.german: "Bereits installiert", .english: "Already installed", .french: "Déjà installé", .spanish: "Ya instalado", .italian: "Già installato", .portuguese: "Já instalado", .hindi: "पहले से इंस्टॉल", .chinese: "已安装", .japanese: "インストール済み", .korean: "이미 설치됨", .turkish: "Zaten yüklü", .polish: "Już zainstalowany", .dutch: "Al geïnstalleerd", .arabic: "مثبت بالفعل", .russian: "Уже установлено"],
        "obChatModelDesc": [.german: "Empfohlen — Lokales Sprachmodell via Ollama", .english: "Recommended — Local language model via Ollama", .french: "Recommandé — Modèle local via Ollama", .spanish: "Recomendado — Modelo local vía Ollama", .italian: "Consigliato — Modello locale via Ollama", .portuguese: "Recomendado — Modelo local via Ollama", .hindi: "अनुशंसित — Ollama के माध्यम से स्थानीय मॉडल", .chinese: "推荐 — 通过Ollama的本地模型", .japanese: "推奨 — Ollama経由のローカルモデル", .korean: "권장 — Ollama를 통한 로컬 모델", .turkish: "Önerilen — Ollama ile yerel model", .polish: "Zalecane — Lokalny model via Ollama", .dutch: "Aanbevolen — Lokaal model via Ollama", .arabic: "موصى به — نموذج محلي عبر Ollama", .russian: "Рекомендуется — Локальная модель через Ollama"],
        "obDownloadAndStart": [.german: "Herunterladen & Starten", .english: "Download & Start", .french: "Télécharger & Démarrer", .spanish: "Descargar e Iniciar", .italian: "Scarica & Avvia", .portuguese: "Baixar & Iniciar", .hindi: "डाउनलोड करें और शुरू करें", .chinese: "下载并启动", .japanese: "ダウンロードして開始", .korean: "다운로드 및 시작", .turkish: "İndir & Başlat", .polish: "Pobierz i Uruchom", .dutch: "Downloaden & Starten", .arabic: "تحميل وبدء", .russian: "Скачать и Начать"],
        "obSkip": [.german: "Überspringen", .english: "Skip", .french: "Passer", .spanish: "Omitir", .italian: "Salta", .portuguese: "Pular", .hindi: "छोड़ें", .chinese: "跳过", .japanese: "スキップ", .korean: "건너뛰기", .turkish: "Atla", .polish: "Pomiń", .dutch: "Overslaan", .arabic: "تخطي", .russian: "Пропустить"],
        "obInstallCLI": [.german: "CLI-Tools installieren?", .english: "Install CLI Tools?", .french: "Installer les outils CLI ?", .spanish: "¿Instalar herramientas CLI?", .italian: "Installare gli strumenti CLI?", .portuguese: "Instalar ferramentas CLI?", .hindi: "CLI टूल इंस्टॉल करें?", .chinese: "安装CLI工具？", .japanese: "CLIツールをインストール？", .korean: "CLI 도구 설치?", .turkish: "CLI araçları yüklensin mi?", .polish: "Zainstalować narzędzia CLI?", .dutch: "CLI-tools installeren?", .arabic: "تثبيت أدوات CLI؟", .russian: "Установить CLI инструменты?"],
        "obCLIInstalled": [.german: "CLI installiert ✓", .english: "CLI installed ✓", .french: "CLI installé ✓", .spanish: "CLI instalado ✓", .italian: "CLI installato ✓", .portuguese: "CLI instalado ✓", .hindi: "CLI इंस्टॉल ✓", .chinese: "CLI 已安装 ✓", .japanese: "CLI インストール済 ✓", .korean: "CLI 설치됨 ✓", .turkish: "CLI yüklü ✓", .polish: "CLI zainstalowany ✓", .dutch: "CLI geïnstalleerd ✓", .arabic: "✓ CLI مثبت", .russian: "CLI установлен ✓"],
        "obCLIDesc": [.german: "Ermöglicht den Befehl `kobold` im Terminal.", .english: "Enables the `kobold` command in Terminal.", .french: "Active la commande `kobold` dans le Terminal.", .spanish: "Activa el comando `kobold` en la Terminal.", .italian: "Abilita il comando `kobold` nel Terminale.", .portuguese: "Habilita o comando `kobold` no Terminal.", .hindi: "टर्मिनल में `kobold` कमांड सक्रिय करता है।", .chinese: "在终端中启用`kobold`命令。", .japanese: "ターミナルで`kobold`コマンドを有効にします。", .korean: "터미널에서 `kobold` 명령을 활성화합니다.", .turkish: "Terminalde `kobold` komutunu etkinleştirir.", .polish: "Włącza komendę `kobold` w Terminalu.", .dutch: "Schakelt het `kobold` commando in Terminal in.", .arabic: ".يفعّل أمر `kobold` في الطرفية", .russian: "Включает команду `kobold` в Терминале."],
    ]

    /// Dictionary lookup helper with English fallback
    private func tr(_ key: String) -> String {
        Self.t[key]?[self] ?? Self.t[key]?[.english] ?? key
    }

    // MARK: - UI String Properties (dictionary-backed)
    var chat: String            { tr("chat") }
    var dashboard: String       { tr("dashboard") }
    var memory: String          { tr("memory") }
    var tasks: String           { tr("tasks") }
    var models: String          { tr("models") }
    var team: String            { tr("team") }
    var agents: String          { tr("agents") }
    var settings: String        { tr("settings") }
    var connected: String       { tr("connected") }
    var offline: String         { tr("offline") }
    var clearHistory: String    { tr("clearHistory") }
    var typeMessage: String     { tr("typeMessage") }
    var toolsAvailable: String  { tr("toolsAvailable") }
    var startConversation: String { tr("startConversation") }
    var thinking: String        { tr("thinking") }

    // MARK: - Onboarding Strings
    var obContinue: String      { tr("obContinue") }
    var obBack: String          { tr("obBack") }
    var obInstall: String       { tr("obInstall") }
    var obLetsGo: String        { tr("obLetsGo") }
    var obStartWith: String     { tr("obStartWith") }
    var obBeginHatching: String { tr("obBeginHatching") }
    var obEggSubtitle: String   { tr("obEggSubtitle") }
    var obSomethingStirs: String { tr("obSomethingStirs") }
    var obNameTitle: String     { tr("obNameTitle") }
    var obNameSubtitle: String  { tr("obNameSubtitle") }
    var obNamePlaceholder: String { tr("obNamePlaceholder") }
    var obKoboldNamePrompt: String { tr("obKoboldNamePrompt") }
    var obKoboldNamePlaceholder: String { tr("obKoboldNamePlaceholder") }
    var obPersonalityTitle: String { tr("obPersonalityTitle") }
    var obPersonalitySubtitle: String { tr("obPersonalitySubtitle") }
    var obUseTitle: String      { tr("obUseTitle") }
    var obUseSubtitle: String   { tr("obUseSubtitle") }
    var obHatch: String         { tr("obHatch") }
    var obHatching: String      { tr("obHatching") }
    var obSettingUp: String     { tr("obSettingUp") }
    var obLoadingMemory: String { tr("obLoadingMemory") }
    var obWakingUp: String      { tr("obWakingUp") }
    var obInstallOllama: String { tr("obInstallOllama") }
    var obOllamaInstalled: String { tr("obOllamaInstalled") }
    var obOllamaDesc: String    { tr("obOllamaDesc") }
    var obLanguagePrompt: String { tr("obLanguagePrompt") }
    var obLanguagePicker: String { tr("obLanguagePicker") }
    var obModelsTitle: String    { tr("obModelsTitle") }
    var obModelsSubtitle: String { tr("obModelsSubtitle") }
    var obChatModel: String     { tr("obChatModel") }
    var obAlreadyInstalled: String { tr("obAlreadyInstalled") }
    var obChatModelDesc: String { tr("obChatModelDesc") }
    var obDownloadAndStart: String { tr("obDownloadAndStart") }
    var obSkip: String          { tr("obSkip") }
    var obInstallCLI: String    { tr("obInstallCLI") }
    var obCLIInstalled: String  { tr("obCLIInstalled") }
    var obCLIDesc: String       { tr("obCLIDesc") }
}

// MARK: - LocalizationManager

@MainActor
class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    @AppStorage("kobold.language") var languageCode: String = AppLanguage.german.rawValue

    var language: AppLanguage {
        get { AppLanguage(rawValue: languageCode) ?? .german }
        set { languageCode = newValue.rawValue }
    }

    private init() {}
}
