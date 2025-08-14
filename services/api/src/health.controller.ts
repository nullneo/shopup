import { Controller, Get } from '@nestjs/common';
import { Client } from 'pg';

@Controller('healthz')
export class HealthController {
  @Get()
  get() { return { ok: true }; }

  @Get('db')
  async db() {
    const url = process.env.DATABASE_URL;
    const client = new Client({ connectionString: url });
    try {
      await client.connect();
      const r = await client.query('select 1 as ok');
      return { db: r.rows[0].ok === 1 };
    } catch (e: any) {
      return { db: false, error: e.message };
    } finally {
      await client.end();
    }
  }
}