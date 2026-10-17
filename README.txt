Dell iDRAC KVM-launcher (Windows)
=================================

Åbner den virtuelle konsol (skærm, tastatur og mus) på en Dell-server med
iDRAC6 - uden at du selv skal installere Java, hente filer eller rette i
sikkerhedsindstillinger.

Originalen er lavet af: https://gist.github.com/xbb/4fd651c2493ad9284dbcb827dc8886d6

Krav: Windows 10 eller 11 (64-bit) og netværksadgang til iDRAC'en.


Kom i gang (3 trin)
-------------------
1. Hent dell_idrac_launcher-vX.Y.Z.zip under "Releases" på GitHub.
2. Højreklik på zip-filen og vælg "Udpak alle". Start IKKE filerne inde
   fra zip-filen - de skal pakkes ud først.
3. Dobbeltklik på idrac.bat og skriv:
     - iDRAC'ens IP-adresse (fx 192.168.1.120)
     - brugernavn (tryk bare Enter for "root")
     - password (Dells standard er "calvin")

Første gang mod en ny server tager det lidt længere, fordi programmet
henter konsol-filerne fra iDRAC'en. Derefter åbner konsollen med det samme.

Når konsollen er startet, lukker det sorte vindue af sig selv.


Det sker automatisk
-------------------
- Java: Har pc'en ikke Java, installeres den medfølgende Java 7 i C:\jre.
  Windows spørger én gang om administratorrettigheder - klik "Ja".
- Konsol-filerne (avctKVM.jar og de tilhørende DLL'er) hentes direkte fra
  iDRAC'en og gemmes i %LOCALAPPDATA%\dell_idrac_launcher\cache.
- Selvsignerede certifikater og gammel kryptering (TLS 1.0/SSLv3), som
  iDRAC6 bruger, accepteres. Har Windows slået gammel TLS fra, hentes
  filerne i stedet via Java.
- Er de gemte konsol-filer i stykker, hentes de automatisk igen.
- Programmet tjekker først, om iDRAC'en kan nås, og siger tydeligt til,
  hvis den ikke kan.
- Du kan godt indsætte en hel adresse som https://192.168.1.120/ - den
  bliver ryddet op automatisk.


Gemte servere (endnu hurtigere)
-------------------------------
Når du har skrevet en ny IP-adresse og konsollen er startet, spørger
programmet, om serveren skal gemmes i hosts.txt. Svarer du "j", kommer
den med i en nummereret menu næste gang - så er det dobbeltklik + ét tal.

Du kan også selv lave hosts.txt: kopiér hosts.example.txt til hosts.txt
og udfyld den. Én server pr. linje:

    navn;IP[;brugernavn[;password]]

Brugernavn og password kan udelades - så spørger programmet.
OBS: Gemte passwords står i klartekst i hosts.txt.


Én genvej pr. server (ægte "one click")
---------------------------------------
Højreklik på idrac.bat > "Opret genvej". Højreklik på genvejen >
Egenskaber, og tilføj IP, brugernavn og password i feltet "Destination":

    ...\idrac.bat 192.168.1.120 root calvin

Indeholder passwordet specialtegn som & % ^ eller mellemrum, så brug
hosts.txt i stedet - de tegn kan ikke stå sikkert i en genvej.


Hvis noget går galt
-------------------
"Kan ikke få forbindelse til ..."
    IP-adressen er forkert, iDRAC'en har ikke netværk, eller din pc er på
    et net, der ikke kan nå den. Prøv at åbne https://<IP>/ i en browser.

"Advarsel: port 5900 (konsollen) svarer ikke"
    Webdelen svarer, men konsolporten er lukket - typisk en firewall
    mellem dig og iDRAC'en, eller at virtuel konsol er slået fra i
    iDRAC'ens indstillinger.

Konsollen åbner, men siger at login fejler
    Forkert brugernavn eller password. Ret det i hosts.txt, hvis det er
    gemt dér.

"Installationen blev afbrudt"
    Der blev ikke klikket "Ja" til administratorrettigheder. Start
    idrac.bat igen og klik "Ja".

Alt andet
    Prøv at hente konsol-filerne forfra ved at køre fra en kommandolinje:

        idrac.bat 192.168.1.120 root calvin -Refresh

    Logfiler fra konsollen ligger i %LOCALAPPDATA%\dell_idrac_launcher\logs.
    Opret en sag på GitHub og vedhæft fejlteksten, hvis det stadig fejler.


Filer
-----
idrac.bat                 Det du dobbeltklikker på
idrac.ps1                 Selve programmet
fetch\                    Hjælpeprogram til at hente filer over gammel TLS
jre-7u80-windows-x64.exe  Java 7 (installeres kun hvis Java mangler)
hosts.example.txt         Skabelon til gemte servere

start_promt.bat og start_quick.bat (kun i git-repoet) er den gamle manuelle
metode og bruges ikke længere.
