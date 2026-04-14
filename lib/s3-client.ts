import { S3Client } from '@aws-sdk/client-s3';

export function createS3Client(): S3Client {
  return new S3Client({
    region: process.env.AWS_REGION ?? 'us-east-1',
  });
}

export const S3_BUCKETS = {
  radarTiles: process.env.S3_RADAR_BUCKET ?? 'radar-tiles',
  forecastTiles: process.env.S3_FORECAST_BUCKET ?? 'forecast-tiles',
};

// Each bucket has its own CloudFront distribution.
export const S3_PUBLIC_URLS = {
  radarTiles: process.env.CLOUDFRONT_RADAR_URL ?? '',
  forecastTiles: process.env.CLOUDFRONT_FORECAST_URL ?? '',
} as const;
