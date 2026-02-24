import puppeteer from 'puppeteer';

(async () => {
  const browser = await puppeteer.launch({headless: "new"});
  const page = await browser.newPage();
  await page.setViewport({width: 800, height: 600});
  
  page.on('console', msg => console.log('BROWSER LOG:', msg.text()));
  page.on('pageerror', err => console.log('BROWSER ERROR:', err.message));

  await page.goto('http://localhost:5173', {waitUntil: 'networkidle0'});
  
  // wait 2 seconds for deckgl to load
  await new Promise(r => setTimeout(r, 2000));
  await page.screenshot({path: 'screenshot1.png'});
  
  await new Promise(r => setTimeout(r, 1000));
  await page.screenshot({path: 'screenshot2.png'});
  
  await browser.close();
})();
