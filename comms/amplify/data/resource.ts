import { type ClientSchema, a, defineData } from '@aws-amplify/backend';

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
    .authorization(allow => [
      allow.ownerDefinedIn('phoneNumber').to(['read']),
      allow.authenticated('identityPool').to(['create', 'read', 'update', 'delete'])
    ]),
});

export type Schema = ClientSchema<typeof schema>;

export const data = defineData({
  schema,
  authorizationModes: {
    defaultAuthorizationMode: 'iam',
  },
});