import { defineConfig } from "@neon/config/v1";

export default defineConfig({
  auth: true,
  dataApi: true,
  functions: {
    timewebs3: {
      name: "TestPatan Timeweb S3",
      source: "./functions/timewebs3.ts",
      env: {
        TIMEWEB_S3_BUCKET: { value: process.env.TIMEWEB_S3_BUCKET, required: true },
        TIMEWEB_S3_ACCESS_KEY: { value: process.env.TIMEWEB_S3_ACCESS_KEY, required: true },
        TIMEWEB_S3_SECRET_KEY: { value: process.env.TIMEWEB_S3_SECRET_KEY, required: true },
        TIMEWEB_S3_ENDPOINT: { value: process.env.TIMEWEB_S3_ENDPOINT, required: true },
        TIMEWEB_S3_REGION: { value: process.env.TIMEWEB_S3_REGION, required: true },
        ALLOWED_ORIGIN: { value: process.env.ALLOWED_ORIGIN, required: true },
      },
    },
  },
});
