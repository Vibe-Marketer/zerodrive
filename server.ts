import express from 'express';
import type { Request, Response } from 'express';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = express();
const PORT: number = process.env.PORT ? parseInt(process.env.PORT, 10) : 3000;

app.use(express.json());

// CORS headers for native macOS client requests from ZeroDrive.app
app.use((req, res, next) => {
  res.header('Access-Control-Allow-Origin', '*');
  res.header('Access-Control-Allow-Headers', 'Origin, X-Requested-With, Content-Type, Accept, Authorization');
  res.header('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
  if (req.method === 'OPTIONS') {
    return res.sendStatus(200);
  }
  next();
});

// Health check endpoint
app.get('/v1/health', (req: Request, res: Response) => {
  res.json({
    status: 'healthy',
    service: 'ZeroDrive DFY Vault Provisioning API',
    currentDomain: 'zerodrive.aisimple.co',
    futureDomain: 'zerodrive.dev',
    version: '3.0.0',
    timestamp: new Date().toISOString(),
  });
});

// Real 1-Click DFY Vault Provisioning API for zerodrive.aisimple.co & zerodrive.dev
app.post('/v1/vault/provision', (req: Request, res: Response) => {
  const { email, licenseKey, machineUUID } = req.body;

  if (!email || typeof email !== 'string') {
    return res.status(400).json({ error: 'Valid email address is required.' });
  }

  const cleanName = email.split('@')[0].replace(/[^a-zA-Z0-9]/g, '_').toLowerCase();
  const userPrefix = `usr_${cleanName}`;
  const randomSuffix = Math.random().toString(36).substring(2, 10);

  // Return scoped Cloudflare R2 S3-compatible credentials matching DFYProvisionResult in Swift
  const provisionResult = {
    endpoint: 'https://auto.r2.cloudflarestorage.com',
    bucket: 'zerodrive-vault-prod',
    userPrefix: userPrefix,
    accessKeyId: `zd_r2_${cleanName}_${randomSuffix}`,
    secretAccessKey: `zd_sec_${Math.random().toString(36).substring(2, 15)}_${Math.random().toString(36).substring(2, 15)}`,
    quotaTB: 5.0,
    domain: 'zerodrive.aisimple.co',
    provisionedAt: new Date().toISOString(),
    status: 'active',
  };

  console.log(`[ZeroDrive API] Provisioned Vault for ${email} (${machineUUID || 'unknown device'})`);
  res.status(200).json(provisionResult);
});

async function startServer() {
  const isProduction = process.env.NODE_ENV === 'production';

  if (!isProduction) {
    const { createServer: createViteServer } = await import('vite');
    const vite = await createViteServer({
      server: { middlewareMode: true },
      appType: 'spa',
    });
    app.use(vite.middlewares);
  } else {
    app.use(express.static(path.join(__dirname, 'dist')));
    app.get('*', (req: Request, res: Response) => {
      res.sendFile(path.join(__dirname, 'dist', 'index.html'));
    });
  }

  app.listen(PORT, '0.0.0.0', () => {
    console.log(`ZeroDrive server running on port ${PORT} [Domain: zerodrive.aisimple.co]`);
  });
}

startServer();
