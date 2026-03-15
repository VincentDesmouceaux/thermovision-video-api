const form = document.getElementById('uploadForm');
const fileInput = document.getElementById('fileInput');
const statusEl = document.getElementById('status');
const resultEl = document.getElementById('result');

form.addEventListener('submit', async (e) => {
  e.preventDefault();
  if (!fileInput.files.length) {
    statusEl.textContent = 'Please choose a file';
    return;
  }
  const file = fileInput.files[0];
  statusEl.textContent = 'Uploading...';
  resultEl.textContent = '';

  const fd = new FormData();
  fd.append('file', file, file.name);

  try {
    const resp = await fetch('/upload', {
      method: 'POST',
      body: fd
    });
    const json = await resp.json();
    if (!resp.ok) {
      statusEl.textContent = 'Upload failed';
      resultEl.textContent = JSON.stringify(json, null, 2);
    } else {
      statusEl.textContent = 'Upload succeeded';
      resultEl.textContent = JSON.stringify(json, null, 2);
    }
  } catch (err) {
    statusEl.textContent = 'Error';
    resultEl.textContent = err.toString();
  }
});
