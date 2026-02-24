import puppeteer from 'puppeteer';

(async () => {
  const browser = await puppeteer.launch({headless: "new"});
  const page = await browser.newPage();
  
  page.on('console', msg => {
    console.log('BROWSER LOG:', msg.text());
  });
  page.on('pageerror', err => {
    console.log('BROWSER ERROR:', err.message);
    console.log('STACK:', err.stack);
  });

  await page.goto('http://localhost:5173', {waitUntil: 'networkidle2'});
  
  // wait 2 seconds for deckgl to load
  await new Promise(r => setTimeout(r, 2000));
  
  await browser.close();
})();
