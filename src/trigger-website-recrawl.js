'use strict';

const { GoogleAuth } = require('google-auth-library');

// Website store — the PROVEN primary site store (interlisp-web-sites_1741606671710).
// Override via WEBSITE_DATA_STORE_ID when targeting a different site data store.
const PROJECT_ID = process.env.PROJECT_ID || 'interlispsearch';
const LOCATION = 'global';
const DATA_STORE_ID = process.env.WEBSITE_DATA_STORE_ID || 'interlisp-web-sites_1741606671710';

const auth = new GoogleAuth({
  scopes: ['https://www.googleapis.com/auth/cloud-platform']
});

exports.recrawlWebsite = async (message, context) => {
  console.log(`[${new Date().toISOString()}] Starting website recrawl...`);
  
  try {
    const client = await auth.getClient();
    const token = await client.getAccessToken();
    
    // Get target sites
    const targetSitesUrl = `https://discoveryengine.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/collections/default_collection/dataStores/${DATA_STORE_ID}/siteSearchEngine/targetSites`;
    
    console.log(`Fetching target sites from: ${targetSitesUrl}`);
    
    const targetSitesResponse = await fetch(targetSitesUrl, {
      method: 'GET',
      headers: {
        'Authorization': `Bearer ${token.token}`,
        'x-goog-user-project': PROJECT_ID
      }
    });
    
    if (!targetSitesResponse.ok) {
      throw new Error(`Failed to fetch target sites: ${targetSitesResponse.statusText}`);
    }
    
    const targetSitesData = await targetSitesResponse.json();
    const targetSites = targetSitesData.targetSites || [];
    
    console.log(`Found ${targetSites.length} target sites`);
    
    if (targetSites.length === 0) {
      console.warn('No target sites found. Data store may not be initialized.');
      return;
    }
    
    // Trigger recrawl for each target site
    const recrawlResults = [];
    
    for (const site of targetSites) {
      try {
        console.log(`Triggering recrawl for: ${site.providedUriPattern}`);
        
        const recrawlUrl = `https://discoveryengine.googleapis.com/v1/${site.name}:recrawl`;
        
        const recrawlResponse = await fetch(recrawlUrl, {
          method: 'POST',
          headers: {
            'Authorization': `Bearer ${token.token}`,
            'Content-Type': 'application/json',
            'x-goog-user-project': PROJECT_ID
          },
          body: JSON.stringify({})
        });
        
        if (!recrawlResponse.ok) {
          const errorText = await recrawlResponse.text();
          console.error(`Recrawl failed for ${site.providedUriPattern}: ${recrawlResponse.statusText}`);
          console.error(`Error details: ${errorText}`);
          recrawlResults.push({
            pattern: site.providedUriPattern,
            status: 'FAILED',
            error: recrawlResponse.statusText
          });
        } else {
          const recrawlData = await recrawlResponse.json();
          console.log(`Recrawl triggered for ${site.providedUriPattern}`);
          console.log(`Operation: ${recrawlData.name}`);
          recrawlResults.push({
            pattern: site.providedUriPattern,
            status: 'SUCCESS',
            operation: recrawlData.name
          });
        }
      } catch (siteError) {
        console.error(`Error recrawling ${site.providedUriPattern}:`, siteError.message);
        recrawlResults.push({
          pattern: site.providedUriPattern,
          status: 'ERROR',
          error: siteError.message
        });
      }
    }
    
    console.log(`[${new Date().toISOString()}] Website recrawl completed`);
    console.log(JSON.stringify(recrawlResults, null, 2));
    
    return recrawlResults;
    
  } catch (err) {
    console.error(`[${new Date().toISOString()}] Recrawl error:`, err);
    throw err;
  }
};
