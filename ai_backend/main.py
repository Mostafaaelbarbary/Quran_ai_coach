# ai_backend/main.py  (FULL UPDATED FILE - copy/paste)

import re
import uuid
import subprocess
from pathlib import Path

from fastapi import FastAPI, UploadFile, File, Query
from fastapi.middleware.cors import CORSMiddleware
import whisper

from ai_backend.knowledge_base import knowledge_base

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # dev only
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

print("⏳ Loading Whisper model...")
model = whisper.load_model("base")
print("✅ Whisper loaded")


# -----------------------------
# Recitation / Scoring Settings
# -----------------------------

DEFAULT_EXPECTED_TEXT = "الحمد لله رب العالمين"

EXPECTED = {
    (1, 2): "الحمد لله رب العالمين",
    # (2, 255): "اللَّهُ لَا إِلَٰهَ إِلَّا هُوَ الْحَيُّ الْقَيُّومُ",
}

def normalize_arabic(s: str) -> str:
    """Light normalization: trims + collapses spaces."""
    return " ".join((s or "").strip().split())

def get_everyayah_url(surah: int, ayah: int, reciter_folder: str = "Alafasy_128kbps") -> str:
    """Generates the reference audio URL from EveryAyah (e.g., 001002.mp3)."""
    key = f"{surah:03d}{ayah:03d}.mp3"
    return f"https://everyayah.com/data/{reciter_folder}/{key}"


# -----------------------------
# Safe Q&A (Intent + Debug Mode)
# -----------------------------

def normalize_q(text: str) -> str:
    text = (text or "").lower().strip()
    text = re.sub(r"\s+", " ", text)
    return text

# IMPORTANT:
# Keys in INTENTS MUST match keys in knowledge_base
INTENTS = {
    "pricing": [
        "price", "pricing", "cost", "subscription", "plan", "plans", "how much",
        "سعر", "الاشتراك", "اشتراك", "تكلفة", "باقة", "الباقات"
    ],
    "trial": [
        "trial", "free trial", "try", "demo", "free",
        "تجربة", "تجريبي", "مجاني", "فترة تجريبية"
    ],
    "devices": [
        "device", "devices", "phone", "tablet", "computer", "works on",
        "جهاز", "أجهزة", "موبايل", "هاتف", "تابلت", "كمبيوتر"
    ],
    "age": [
        "age", "how old", "from what age", "kids age", "child age",
        "عمر", "سن", "كم العمر", "من عمر"
    ],
    "tajweed_help": [
        "tajweed", "rules", "makharij", "ghunna", "madd", "ikhfa", "idgham",
        "تجويد", "أحكام", "احكام", "مد", "غنة", "غنه", "إخفاء", "اخفاء", "إدغام", "ادغام", "قلقلة"
    ],
    "mistake_detection": [
        "mistake", "mistakes", "error", "errors", "detect", "detection", "correction",
        "خطأ", "أخطاء", "اخطاء", "تصحيح", "كشف", "يكشف", "اكتشاف"
    ],
    "mic_problem": [
        "mic", "microphone", "permission", "recording permission", "can't record",
        "ميكروفون", "مايك", "إذن", "اذن", "سماح", "صلاحية"
    ],
    "audio_problem": [
        "audio", "sound", "no sound", "silent", "speaker", "volume",
        "صوت", "لا يوجد صوت", "مفيش صوت", "سماعة", "الصوت"
    ],
    "kids_mode": [
        "kids", "kid", "child", "children", "for kids",
        "أطفال", "طفل", "للأطفال", "للاطفال"
    ],
    "what_is_quran": [
        "quran", "what is quran", "what's quran",
        "القرآن", "القران", "ما هو القرآن", "ما هو القران"
    ],
}

def detect_intent(query: str):
    """Return (intent, matched_term) or (None, None)."""
    for intent, terms in INTENTS.items():
        for t in terms:
            if t in query:
                return intent, t
    return None, None


# -----------------------------
# API Endpoints
# -----------------------------

@app.get("/")
def health():
    return {"status": "ok"}

@app.post("/analyze_recitation")
async def analyze_recitation(
    audio: UploadFile = File(...),
    surah: int = Query(1, ge=1, le=114),
    ayah: int = Query(2, ge=1, le=300),
    reciter: str = Query("Alafasy_128kbps")
):
    audio_bytes = await audio.read()

    tmp_id = uuid.uuid4().hex
    webm_path = Path(f"temp_{tmp_id}.webm")
    wav_path = Path(f"temp_{tmp_id}.wav")

    try:
        webm_path.write_bytes(audio_bytes)

        subprocess.run(
            ["ffmpeg", "-y", "-i", str(webm_path), "-ar", "16000", "-ac", "1", str(wav_path)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=True,
        )

        result = model.transcribe(str(wav_path), language="ar")
        recognized = normalize_arabic(result.get("text", ""))

        expected_raw = EXPECTED.get((surah, ayah), DEFAULT_EXPECTED_TEXT)
        expected = normalize_arabic(expected_raw)

        mistakes = []
        if expected and expected in recognized:
            score = 100
        else:
            rec_words = recognized.split()
            exp_words = expected.split()

            max_len = max(len(rec_words), len(exp_words))
            for i in range(max_len):
                said = rec_words[i] if i < len(rec_words) else ""
                exp = exp_words[i] if i < len(exp_words) else ""
                if said != exp:
                    mistakes.append({"index": i, "expected": exp, "said": said})

            score = max(0, 100 - (15 * len(mistakes)))

        return {
            "surah": surah,
            "ayah": ayah,
            "expected_text": expected,
            "recognized_text": recognized,
            "mistakes": mistakes,
            "score": score,
            "reference_audio_url": get_everyayah_url(surah, ayah, reciter_folder=reciter),
            "received_filename": audio.filename,
            "received_bytes": len(audio_bytes),
        }

    except Exception as e:
        return {"error": str(e)}

    finally:
        if webm_path.exists():
            webm_path.unlink()
        if wav_path.exists():
            wav_path.unlink()


@app.get("/ask")
def ask_question(
    q: str = Query(..., min_length=1),
    debug: bool = Query(False)
):
    query = normalize_q(q)

    intent, matched_term = detect_intent(query)

    # No match -> return debug info so you SEE why
    if not intent:
        resp = {"answer": "No intent matched. Try another wording."}
        if debug:
            resp["debug"] = {
                "query_received": q,
                "query_normalized": query,
                "matched_intent": None,
                "matched_term": None,
                "available_kb_keys": list(knowledge_base.keys()),
                "intents": list(INTENTS.keys()),
                "tip": "Add more Arabic/English keywords to INTENTS for your real user questions."
            }
        return resp

    # Intent matched, but KB missing that key
    if intent not in knowledge_base:
        resp = {"answer": "Intent matched but no answer exists in knowledge_base for it."}
        if debug:
            resp["debug"] = {
                "query_received": q,
                "query_normalized": query,
                "matched_intent": intent,
                "matched_term": matched_term,
                "kb_has_key": False,
                "available_kb_keys": list(knowledge_base.keys()),
            }
        return resp

    # Success
    resp = {"answer": knowledge_base[intent]}
    if debug:
        resp["debug"] = {
            "query_received": q,
            "query_normalized": query,
            "matched_intent": intent,
            "matched_term": matched_term,
            "kb_has_key": True,
        }
    return resp