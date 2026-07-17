# Wardrobe op Synology DS920+

GitHub is de enige bron voor de applicatie en de deploymentconfiguratie:

```text
https://github.com/mho747/wardrobe.git
```

De Synology kloont die repository direct naar
`/volume1/docker/wardrobe/repository`. Er worden geen Git-bundles,
SMB-kopieen of handmatige broncodewijzigingen op de NAS gebruikt.

## Persistentie en netwerk

Alle gebruikersdata staat in `/volume1/docker/wardrobe/data`, inclusief
`model-reference.png` en de lokale JSON-database. Back-ups, update-status en
tijdelijke kandidaattests blijven beperkt tot `backups`, `update-state` en
`candidates` onder dezelfde `wardrobe`-map.

De lokale, niet-geversioneerde `.env` bevat de OpenAI-key en krijgt modus
`0600`. De app publiceert poort 4173 uitsluitend op het NAS-LAN-adres:

```dotenv
WARDROBE_BIND_ADDRESS=192.168.192.150
WARDROBE_HOST_PORT=4173
```

Gebruik nooit `0.0.0.0`, maak geen router-port-forwarding voor 4173 en
publiceer geen reverse proxy naar deze dienst. De containers draaien als
UID/GID `1000`, met alleen-lezen rootfilesystem, beperkte capabilities,
healthchecks en automatische herstart. Alleen `/tmp` en Vite's tijdelijke
config-cache zijn kortstondige `tmpfs`-mappen; geen applicatie- of gebruikersdata
staat daarin.

## Eerste installatie

De installatie maakt alleen `/volume1/docker/wardrobe` met de submappen
`repository`, `data`, `backups`, `update-state` en `candidates`. De schrijfbare
data-mappen krijgen eigenaar `1000:1000` en modus `0700`.

De root-installatie kloont rechtstreeks vanaf GitHub, maakt de lokale `.env`,
plaatst de referentiefoto in `data/` en voert daarna
`scripts/deploy-synology.sh` uit. Die bouwt de image uit het lockbestand,
controleert healthcheck en import-configuratie-API, herstart de app, maakt en
valideert een directe `tar.gz`-back-up, en verifieert de LAN-poortbinding en
Git-revisie.

De installatie is pas geslaagd wanneer de API `ready: true` teruggeeft. Dat
bevestigt de geheime key en de lokale referentiefoto zonder de key te tonen of
een betaalde OpenAI-aanroep te doen.

## OpenAI-key veilig vervangen

Vervang een key uitsluitend via het versiebeheer-script op de NAS, uitgevoerd
met een interactieve SSH-terminal. Het vraagt de key verborgen via `/dev/tty`,
vervangt alleen de overeenkomstige regel in de lokale `.env`, herstart alleen
de `wardrobe`-container en herstelt de vorige `.env` wanneer de healthcheck
faalt. Er vindt geen OpenAI-aanroep plaats.

## Updates en rollback

`wardrobe-update-check` controleert dagelijks alleen GitHub en schrijft de
status naar `update-state/update-status.json`; deze service installeert nooit
iets. Elke update doorloopt eerst `scripts/test-update.sh` in een tijdelijke
container met lege testdata, geen OpenAI-key en alleen `127.0.0.1:4174`.

Wijzigingen aan database, API, OpenAI-modellen, mogelijke kosten, security,
dependencies, Docker/Compose, `.env` of scripts stoppen met
`REQUIRES_APPROVAL`. Pas na uitdrukkelijke toestemming mag
`scripts/apply-update.sh --approved-sensitive` draaien. Die maakt eerst een
backup, accepteert uitsluitend een fast-forward uit de GitHub-bron, verifieert
de nieuwe container en zet bij een fout automatisch de vorige Git-revisie terug.
De rollback wordt met dezelfde healthcheck en API-controle geverifieerd.

Voor een aantoonbare hersteltest is `scripts/test-rollback.sh` beschikbaar.
Dat script kloont opnieuw vanaf GitHub naar een tijdelijke submap onder
`candidates`, gebruikt alleen `127.0.0.1:4175` (en `4174` voor de kandidaat),
een testreferentie en een niet-werkende testkey. Het forceert een eenmalige
fout in de kandidaatrelease, controleert dat de automatische rollback de
vorige Git-revisie en een healthy container terugbrengt, en verwijdert daarna
alle tijdelijke containers en data. Het doet geen OpenAI-aanroep en raakt
poort 4173 of productiedata niet.

Een applicatierollback wijzigt nooit `data/`. Herstel van gebruikersdata uit
een gevalideerde back-up is een aparte, expliciet goed te keuren handeling.
