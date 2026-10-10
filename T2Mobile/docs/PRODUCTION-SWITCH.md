# Making the new app the one production code base (T2 -> T2T)

Nathan, 2026-10-09: "we don't need separate /T2 and /T2T code bases any more ... archive any
older versions of the original /T2 and make our new interface the default, i.e. T2T the
production code base to run the shiny tools on this server."

Written by Claude the same night; nothing below has been executed. The steps change the
Nginx configuration and the running containers, so they wait for Nathan's "deploy".

## What runs today

| URL | container | code | data |
|---|---|---|---|
| /T2/ | `shiny-t2` (image shinypublic:2026.10, old R/Shiny) | `/scratch/shinyusb/T2`, repo `main` at ad37b69 (2026-09) | the July files in `/scratch/shinyusb/T2` (tcga.db 36 GB, datasets/) |
| /T2T/ | `shiny-t2t` (image shinyt2t:2026.10) | `/scratch/shinyusb/T2T`, repo `main` at 297a0cb + `/scratch/shinyusb/Thanos` | `/scratch/shinyusb/T2-data-20261005` |
| /T2Tc/ | pool `shinypublic-shiny-t2tc-1..4` behind `haproxy-t2tc` | same as T2T | same |
| /api/t2/ | `t2api` | image t2api:2026.10 | same |

(`/scratch/Docker/ShinyPublic/docker-compose.yml`, `/scratch/Docker/Nginx/nginx.conf`.)

## The switch, in order

1. **Merge and deploy the new code.** Nathan merges `post-1.0` into `main` (the branch has
   this night's work: data sources and presets, the API layer, ranked search, descriptions,
   the contact form, the service changes). Then on the server:

       /scratch/Docker/ShinyPublic/scripts/deploy.sh T2T      # pulls main into /scratch/shinyusb/T2T (+ Thanos), restarts shiny-t2t
       /scratch/Docker/ShinyPublic/scripts/pool.sh restart    # (or whatever pool.sh offers) the T2Tc instances

   The Toil database the sites serve lacks the `source_col` keys: the GTEx / TARGET parts
   appear only after a database deploy (NEW directory, see below). Everything else works on
   the served files.

2. **The service.** `docker build -t t2api:2026.10 /scratch/nathan/R/T2/T2Mobile/service && cd
   /scratch/Docker/ShinyPublic && docker compose up -d t2api` (adds `sources`, preset counts,
   `/probes?all=1`, the in-flight cap; the 1.0 app in review is unaffected: additions only,
   verified with the UI suite on the simulator against the new service). Never during an iOS
   UI run.

3. **The Shiny sites over the service (optional, recommended).** Add to the `shiny-t2t` and
   `shiny-t2tc` services in the compose file:

       environment:
         T2_API_URL: http://t2api:8080
         T2_CONTACT_URL: http://t2api:8080/v1/contact

   and drop their two database volume lines (the containers then mount no data files). The
   contact form appears on About with `T2_CONTACT_URL`. Without `T2_API_URL` the sites keep
   reading the files and the contact form is hidden unless `T2_CONTACT_URL` is set on its own.

4. **Point /T2/ at the new app.** In `nginx.conf` replace

       location /T2/      { set $app shiny-t2;      proxy_pass http://$app:3838; }

   with the pool (the sturdier choice: many visitors, one browser per instance):

       location /T2/ {
           set $app haproxy-t2tc;
           proxy_pass http://$app:8080;
           proxy_cookie_path / /T2/;
           proxy_cookie_flags T2TC secure samesite=lax;
       }

   (or `set $app shiny-t2t; proxy_pass http://$app:3838;` for the single instance). Keep
   `/T2T/` and `/T2Tc/` as they are for now, so links in circulation keep working; retire
   them later with `return 301 /T2/;`. Then `docker exec nginx-nginx-1 nginx -t && docker
   exec nginx-nginx-1 nginx -s reload`.

5. **Stop and archive the old app.** `docker compose stop shiny-t2 && docker compose rm
   shiny-t2` (and comment its service out of the compose file, plus `scripts/deploy.sh`'s T2
   entry and port 3851). Move the code: `mv /scratch/shinyusb/T2 /scratch/shinyusb/T2.archive-20261010`
   (the directory also holds the July database files, 60 GB: delete them once the new
   files have been in production for a while; `/scratch/shinyusb/T2.legacy` and
   `T2.22may2023` are older archives of the same kind). `/scratch/shinyusb/T2T/tcga.db` and
   `datasets` are symlinks into the old `T2` directory: remove them (the containers mount
   the data directly).

6. **Check** /T2/ in a browser (Select, a plot, Filter, Publish, About with the contact
   form), the pool health in `docker ps`, Nginx's error log.

## Database deploy (for the GTEx / TARGET parts)

The served Toil file needs the four `dataset_meta` keys. Deploy by the standing rule: a NEW
directory, never a write to a served file:

    cp -a /scratch/shinyusb/T2-data-20261005 /scratch/shinyusb/T2-data-20261010   # or hard links for tcga.db
    # write the keys AS THE OWNER of the copy (SQLite needs write on the file and its directory
    # for the journal): the `data` step of deploy-20261010.sh does exactly this, then chmod 644
    # and `dataset_meta.R show` to check

then change the volume lines (t2api, shiny-t2t, shiny-t2tc) to the new directory and
`docker compose up -d`. (The keys are also what the Toil builder writes from now on.)
A copy with the keys already applied, verified against the service this night, is
`/scratch/nathan/R/T2-devdata/datasets/tcgatargetgtex.db` (the development copy + the keys).
