const { defineConfig } = require('@playwright/test');
module.exports = defineConfig({
 testDir:'./tests/browser', testMatch:'auto-cart.spec.cjs',
 timeout:60000, expect:{timeout:20000}, workers:1, retries:0,
 reporter:[['list']], outputDir:'test-results/auto-cart'
});
