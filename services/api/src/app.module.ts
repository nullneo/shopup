import { Module } from '@nestjs/common';
import { HealthController } from './health.controller';
import { MetricsController } from './metrics.controller';
import './metrics';

@Module({ controllers: [HealthController, MetricsController] })
export class AppModule {}
