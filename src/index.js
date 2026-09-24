const http = require('http');

const healthCheck = (endpoint) => {
  return new Promise((resolve, reject) => {
    const req = http.get(endpoint, (res) => {
      resolve({ status: res.statusCode, ok: res.statusCode === 200 });
    });
    req.on('error', (err) => reject(err));
    req.setTimeout(5000, () => {
      req.destroy();
      reject(new Error('Timeout'));
    });
  });
};

const checkEndpoint = async (url, label) => {
  try {
    const result = await healthCheck(url);
    console.log(`  ${label}: ${result.ok ? 'PASS' : 'FAIL'} (${result.status})`);
    return result.ok;
  } catch (err) {
    console.log(`  ${label}: FAIL (${err.message})`);
    return false;
  }
};

module.exports = { healthCheck, checkEndpoint };
