const { spawn } = require('child_process');
const http = require('http');
const fs = require('fs');

const PORT = process.env.PORT || 5757;
const URL = `http://localhost:${PORT}`;

function findChrome() {
  const candidates = {
    win32: [
      'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
      'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
      'C:\\Program Files\\Chromium\\Application\\chrome.exe',
    ],
    darwin: [
      '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      '/Applications/Chromium.app/Contents/MacOS/Chromium',
    ],
    linux: ['/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser'],
  };

  const list = candidates[process.platform] || [];
  const found = list.find((p) => fs.existsSync(p));
  if (!found) {
    throw new Error(
      `Could not find a Chrome/Chromium install for platform "${process.platform}". ` +
        `Set CHROME_PATH env var to the executable path.`
    );
  }
  return found;
}

function waitForServer(url, timeoutMs = 15000) {
  const start = Date.now();
  return new Promise((resolve, reject) => {
    (function attempt() {
      http
        .get(url, (res) => {
          res.resume();
          resolve();
        })
        .on('error', () => {
          if (Date.now() - start > timeoutMs) {
            reject(new Error('Timed out waiting for server to start'));
          } else {
            setTimeout(attempt, 300);
          }
        });
    })();
  });
}

async function main() {
  console.log('Starting server…');
  const server = spawn('node', ['server.js'], { stdio: 'inherit', cwd: __dirname });

  server.on('exit', (code) => {
    console.log(`Server exited with code ${code}`);
    process.exit(code || 0);
  });

  await waitForServer(URL);
  console.log('Server is up, launching Chrome kiosk…');

  const chromePath = process.env.CHROME_PATH || findChrome();
  const chrome = spawn(
    chromePath,
    [
      `--kiosk`,
      `--app=${URL}`,
      '--noerrdialogs',
      '--disable-infobars',
      '--disable-session-crashed-bubble',
      '--overscroll-history-navigation=0',
      `--user-data-dir=${__dirname}/.chrome-profile`,
    ],
    { stdio: 'inherit' }
  );

  chrome.on('exit', (code) => {
    console.log(`Chrome exited with code ${code}, stopping server…`);
    server.kill();
    process.exit(code || 0);
  });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
