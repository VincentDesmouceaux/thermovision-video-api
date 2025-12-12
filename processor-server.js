// processor-server.js (CommonJS)
const express = require('express');
const multer = require('multer');
const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const app = express();
const upload = multer({ dest: os.tmpdir() });

// Chemin vers le script Python
const PYTHON_BIN = process.env.PYTHON_BIN || 'python3';
const THERMAL_SCRIPT =
  process.env.THERMAL_SCRIPT ||
  path.join(__dirname, 'thermal_processor.py');

// Upload d'une vidéo, retour de la vidéo annotée
app.post('/process', upload.single('video'), (req, res) => {
  if (!req.file) {
    return res
      .status(400)
      .json({ error: 'No video file provided (field name: video)' });
  }

  // chemin temp du fichier uploadé (créé dynamiquement par multer)
  const inputPath = req.file.path;
  // on construit dynamiquement la sortie à côté
  const outputPath = inputPath + '_out.mp4';

  // Arguments pour le script Python
  const args = [
    THERMAL_SCRIPT,
    inputPath,
    outputPath,
    '--pLow',
    '0.80',
    '--pHigh',
    '0.98',
    '--gamma',
    '1.2',
    '--alpha',
    '0.6',
    '--stat',
    'avg',
  ];

  console.log('[server] Launching thermal_processor:', PYTHON_BIN, args.join(' '));

  const proc = spawn(PYTHON_BIN, args);

  // Logs envoyés par le script (ceux qu’on a formatés proprement)
  proc.stderr.on('data', (d) => {
    process.stderr.write(d);
    // Optionnel : plus tard tu peux bufferiser ça pour l’exposer au front
  });

  proc.on('error', (err) => {
    console.error('[server] Failed to spawn thermal_processor:', err);
    return res.status(500).json({ error: 'Failed to start processor' });
  });

  proc.on('close', (code) => {
    if (code !== 0) {
      console.error('[server] thermal_processor exited with code', code);
      return res
        .status(500)
        .json({ error: `thermal_processor failed (code ${code})` });
    }

    fs.stat(outputPath, (err, stat) => {
      if (err || !stat) {
        console.error('[server] Output file missing', err);
        return res
          .status(500)
          .json({ error: 'Output video not found after processing' });
      }

      res.setHeader('Content-Type', 'video/mp4');
      res.setHeader(
        'Content-Disposition',
        `attachment; filename="heatmap_${req.file.originalname}"`
      );

      const readStream = fs.createReadStream(outputPath);
      readStream.pipe(res);

      readStream.on('close', () => {
        // nettoyage fichiers temporaires
        fs.unlink(inputPath, () => {});
        fs.unlink(outputPath, () => {});
      });
    });
  });
});

// Petit ping pour vérifier
app.get('/', (_req, res) => {
  res.json({ ok: true, msg: 'Thermal processor (Python) up' });
});

const PORT = process.env.PORT || 4000;
app.listen(PORT, () => {
  console.log(`Thermal processor listening on http://localhost:${PORT}`);
});
