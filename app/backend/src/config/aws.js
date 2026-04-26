'use strict';

// When AWS_ENDPOINT is set, all SDK clients point to LocalStack.
// In production (ECS), this env var is absent and SDK uses real AWS endpoints.

const isLocal = !!process.env.AWS_ENDPOINT;

const baseConfig = {
  region: process.env.AWS_REGION || 'us-east-1',
  ...(isLocal && {
    endpoint:    process.env.AWS_ENDPOINT,
    credentials: {
      accessKeyId:     process.env.AWS_ACCESS_KEY_ID     || 'local',
      secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY || 'local',
    },
    forcePathStyle: true,   // required for LocalStack S3
  }),
};

const { S3Client }              = require('@aws-sdk/client-s3');
const { SQSClient }             = require('@aws-sdk/client-sqs');
const { EventBridgeClient }     = require('@aws-sdk/client-eventbridge');
const { SESClient }             = require('@aws-sdk/client-ses');
const { SecretsManagerClient }  = require('@aws-sdk/client-secrets-manager');
const { SFNClient }             = require('@aws-sdk/client-sfn');

module.exports = {
  s3:      new S3Client(baseConfig),
  sqs:     new SQSClient(baseConfig),
  events:  new EventBridgeClient(baseConfig),
  ses:     new SESClient(baseConfig),
  secrets: new SecretsManagerClient(baseConfig),
  sfn:     new SFNClient(baseConfig),
  isLocal,
};
