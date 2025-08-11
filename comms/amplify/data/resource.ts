import { type ClientSchema, a, defineData } from '@aws-amplify/backend';
import { UserPoolEmail } from 'aws-cdk-lib/aws-cognito';
import { EmailEncoding } from 'aws-cdk-lib/aws-ses-actions';

const schema = a.schema({
  Message: a
    .model({
      id: a.id().required(),
      phoneNumber: a.string().required(),
      sourceName: a.string().required(),
      title: a.string().required(),
      content: a.string().required(),
      timestamp: a.datetime().required(),
      isViewed: a.boolean().default(false).required(),
    })
    .authorization(allow => allow.owner()),
});

export type Schema = ClientSchema<typeof schema>;

export const data = defineData({
  schema,
  authorizationModes: {
    defaultAuthorizationMode: 'userPool',
  },
});