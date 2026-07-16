# Wardrobe op Synology DS920+ (Container Manager)

Deze map bevat de minimale productie-inrichting voor Wardrobe. De applicatiecode en API-routes blijven ongewijzigd: de container start de bestaande Vite Preview-server en de bestaande import-middleware. De Synology-checkout is een eigen lokale Git-bron; GitHub blijft een alleen-lezen upstream voor gecontroleerde kandidaatupdates.

## Wat wordt geïnstalleerd

- `wardrobe`: de app als gebruiker `node` (UID/GID 1000), met alleen-lezen rootbestandssysteem, beperkte Linux-capabilities, healthcheck en `restart: unless-stopped`.
- `wardrobe-backup`: maakt direct een controleerbare `tar.gz`-back-up en daarna elke 24 uur. Alleen `/volume1/docker/wardrobe/data` wordt gelezen; alleen de eigen backupmap wordt beschreven. Back-ups ouder dan 30 dagen worden uitsluitend uit `/volume1/docker/wardrobe/backups` verwijderd. Pas `BACKUP_RETENTION_DAYS` aan voor een andere termijn; `0` schakelt opruimen uit.
- `wardrobe-update-check`: controleert dagelijks de publieke GitHub-branch via de GitHub API en schrijft uitsluitend status naar `/volume1/docker/wardrobe/update-state/update-status.json`. Deze service installeert nooit een update en heeft geen Docker-socket.

Persistente gegevens staan uitsluitend onder:

```text
/volume1/docker/wardrobe/data
```

De referentiefoto moet daar als `model-reference.png` staan. De container mount die map als `/app/data`; de app schrijft dus geen data in de image of repository.

## Netwerk en geheimen

Zet in de lokale, niet-geversioneerde `.env` altijd het LAN-adres van de NAS:

```dotenv
WARDROBE_BIND_ADDRESS=192.168.x.x
WARDROBE_HOST_PORT=4173
```

Vervang het voorbeeldadres door het echte vaste LAN-IP van de DS920+. Gebruik nooit `0.0.0.0`. Daardoor bindt Docker poort 4173 alleen aan de LAN-interface van de NAS. Maak in de router geen port-forwarding voor 4173 en publiceer geen reverse proxy naar deze poort.

Voer `OPENAI_API_KEY` alleen interactief en verborgen in op de NAS in `.env`; sla hem nergens op in Git, logs of chat. Beperk de rechten van `.env` tot eigenaar lezen/schrijven (`0600`). De API-key blijft server-side en wordt niet aan de browser doorgegeven.

De backupbestanden zijn alleen versleuteld wanneer het Synology-volume zelf versleuteld is. Bescherm de NAS en back-uplocatie daarom volgens het bestaande NAS-beleid.

## Voorbereiding op de NAS

Gebruik een aparte checkout, bijvoorbeeld `/volume1/docker/wardrobe/repository`; maak of verwijder geen bestaande container, share of map buiten `/volume1/docker/wardrobe`.

De installatie maakt uitsluitend deze nieuwe mappen aan:

```text
/volume1/docker/wardrobe/data
/volume1/docker/wardrobe/backups
/volume1/docker/wardrobe/update-state
/volume1/docker/wardrobe/candidates
/volume1/docker/wardrobe/repository
```

Geef `data`, `backups`, `update-state` en `candidates` eigenaar UID/GID `1000:1000` en modus `0700`. De app- en hulpcontainers draaien met die niet-root identiteit.

## Gecontroleerde eerste start

Na het veilig aanmaken van `.env`, de referentiefoto en de mappen voert `scripts/deploy-synology.sh` dit uit. Bij de eerste installatie verzorgt `scripts/install-synology-root.sh` de nieuwe lokale Git-checkout, rechten, geheime `.env` en referentiefoto via standaardinvoer; de key komt niet in een commandoregel of log terecht.

1. bouwt de image uit het lockbestand;
2. start de drie eigen containers;
3. controleert healthcheck en de bestaande configuratie-API;
4. herstart de app en controleert healthcheck/API opnieuw;
5. maakt een directe backup, opent die ter validatie en verifieert de LAN-poortbinding.

De procedure slaagt alleen wanneer de API `ready: true` rapporteert. Dat bewijst dat zowel de OpenAI-key als `data/model-reference.png` bruikbaar zijn, zonder de key zelf te tonen of een betaalde OpenAI-aanroep te doen.

## Updatebeleid

`update-status.json` kan `current`, `update_available` of `check_failed` bevatten. Een beschikbare update wordt nooit automatisch geïnstalleerd. `WARDROBE_REVISION` identificeert de exacte lokale deploymentcommit; `WARDROBE_UPSTREAM_REVISION` is de laatst beoordeelde GitHub-revisie.

Voor iedere wijziging geldt:

1. `scripts/test-update.sh` haalt alleen de kandidaatcommit op in een tijdelijke Git-worktree onder `candidates/`.
2. Hij bouwt en start uitsluitend een tijdelijke kandidaatcontainer op `127.0.0.1:4174`, met lege testdata en zonder OpenAI-key. Vervolgens verifieert hij healthcheck en de import-configuratie-API.
3. Hij laat de productiecontainer, productiedata en backups ongemoeid en ruimt de kandidaat op.
4. Elke wijziging aan dependencies, Docker/Compose, `.env`, scripts, API, OpenAI-modellen, security of mogelijke kosten stopt met `REQUIRES_APPROVAL`. Alleen na expliciete beoordeling en toestemming mag zo'n update worden gepromoveerd.

Na zo'n uitdrukkelijke goedkeuring voert alleen `scripts/apply-update.sh --approved-sensitive` de promotie uit. Die test de kandidaat opnieuw, maakt eerst een backup, verifieert daarna de nieuwe container en keert bij iedere fout automatisch terug naar de exacte vorige Git-revisie. De rollback wordt opnieuw met dezelfde healthcheck, API-, restart-, backup- en poortcontrole geverifieerd. Er is geen database-migratie of automatische updatepromotie in deze inrichting.

## Herstel

De productiedata is losgekoppeld van de applicatie-image. Daardoor herstelt een applicatierollback de vorige Git-image zonder `data/` te overschrijven. Herstel van gebruikersdata gebeurt uitsluitend uit een gevalideerd archief in `/volume1/docker/wardrobe/backups` en vereist een afzonderlijke, expliciet goedgekeurde actie.
