const { checkEndpoint } = require('../src/index');

const run = async () => {
  console.log('Running health checks...\n');

  const endpoints = [
    { url: 'http://127.0.0.1:11470', label: 'Engine' },
    { url: 'http://127.0.0.1:8080', label: 'Logs' },
  ];

  let passed = 0;
  let failed = 0;

  for (const ep of endpoints) {
    const ok = await checkEndpoint(ep.url, ep.label);
    if (ok) passed++;
    else failed++;
  }

  console.log(`\nResults: ${passed} passed, ${failed} failed`);
  process.exit(failed > 0 ? 1 : 0);
};

run();
