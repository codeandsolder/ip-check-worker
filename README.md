# Very simple IP checker

w/ Cloudflare worker

## Deployment

- Clone this project
- deploy with wrangler

```console
╭─owen@rackspace ~/ip-check-worker ‹master*›
╰─$ CF_ACCOUNT_ID=11111111111111111111111111111111 wrangler publish
✨  Basic JavaScript project found. Skipping unnecessary build!
✨  Successfully published your script to
 https://ip-check-worker.yourdomain.workers.dev

╭─owen@rackspace ~/ip-check-worker ‹master*›
╰─$ curl -s https://ip-check-worker.yourdomain.workers.dev
169.254.169.254
```
