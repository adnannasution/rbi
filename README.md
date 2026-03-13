# RBI Application - Panduan Deploy ke Railway

## Struktur Project
```
rbi-app/
├── backend/          ← Express.js API Server
│   ├── server.js
│   ├── schema.sql
│   └── package.json
├── frontend/         ← React App
│   ├── src/
│   └── package.json
└── README.md
```

---

## 🚀 Cara Deploy ke Railway (Step by Step)

### LANGKAH 1 — Upload ke GitHub
1. Buat repo baru di GitHub (misalnya `rbi-app`)
2. Upload seluruh folder ini ke repo tersebut
3. Pastikan struktur folder seperti di atas

---

### LANGKAH 2 — Setup di Railway

Buka [railway.app](https://railway.app) → Login → **New Project**

---

### LANGKAH 3 — Tambah PostgreSQL Database

1. Di project kamu, klik **+ New** → **Database** → **Add PostgreSQL**
2. Railway akan otomatis buat database PostgreSQL
3. Klik database yang baru dibuat → tab **Connect**
4. Copy `DATABASE_URL` (bentuknya: `postgresql://...`)

**Setup Schema Database:**
1. Di tab **Query** pada PostgreSQL Railway, paste seluruh isi `backend/schema.sql` dan jalankan
2. Ini akan membuat semua table yang dibutuhkan

---

### LANGKAH 4 — Deploy Backend

1. Di project, klik **+ New** → **GitHub Repo** → pilih repo kamu
2. Pilih folder: `backend` (atur di **Root Directory** → `/backend`)
3. Railway otomatis detect Node.js dan jalankan `npm start`

**Set Environment Variables di Backend:**
Klik service backend → tab **Variables** → tambahkan:

| Variable | Value |
|----------|-------|
| `DATABASE_URL` | *(copy dari PostgreSQL plugin)* |
| `JWT_SECRET` | *(random string panjang, min 32 karakter)* |
| `NODE_ENV` | `production` |
| `PORT` | `3001` |

---

### LANGKAH 5 — Deploy Frontend

1. Di project yang sama, klik **+ New** → **GitHub Repo** → pilih repo yang sama
2. Pilih folder: `frontend` (atur **Root Directory** → `/frontend`)
3. Set **Build Command**: `npm run build`
4. Set **Start Command**: `npx serve -s build -l $PORT`

**Set Environment Variables di Frontend:**
Klik service frontend → tab **Variables** → tambahkan:

| Variable | Value |
|----------|-------|
| `REACT_APP_API_URL` | URL backend kamu (contoh: `https://rbi-backend.up.railway.app`) |

---

### LANGKAH 6 — Update CORS di Backend

Setelah frontend deploy dan dapat URL-nya, update `server.js`:
```js
app.use(cors({
  origin: ['https://rbi-frontend.up.railway.app'] // ganti dengan URL frontend kamu
}));
```

---

## 🔑 Generate JWT_SECRET yang Aman

Jalankan di terminal lokal:
```bash
node -e "console.log(require('crypto').randomBytes(64).toString('hex'))"
```

---

## ✅ Checklist Deploy

- [ ] Code sudah di GitHub
- [ ] PostgreSQL sudah ditambah di Railway
- [ ] Schema SQL sudah dijalankan di database
- [ ] Backend service sudah deploy dengan env vars yang benar
- [ ] Frontend service sudah deploy
- [ ] `REACT_APP_API_URL` di frontend sudah diisi URL backend
- [ ] CORS di backend sudah diupdate dengan URL frontend
- [ ] Test login berhasil
