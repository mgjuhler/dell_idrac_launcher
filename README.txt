Dell iDRAC KVM-launcher (Windows)
=================================

Starter den Java-baserede virtuelle konsol på Dell iDRAC med ét klik.

Originalen er lavet af: https://gist.github.com/xbb/4fd651c2493ad9284dbcb827dc8886d6

Sådan bruges den
----------------
Dobbeltklik på idrac.bat og tast host/IP, brugernavn og password.

Det hele klares automatisk:
- avctKVM.jar og de native biblioteker hentes direkte fra iDRAC'en
  (kun første gang pr. server - de gemmes i cache\-mappen).
- Mangler Java, installeres den medfølgende JRE 7 i C:\jre
  (kræver et enkelt administrator-klik).

Endnu hurtigere: gemte servere
------------------------------
Kopiér hosts.example.txt til hosts.txt og udfyld dine servere.
Så viser idrac.bat en nummereret menu, og med gemt brugernavn/password
er det ét dobbeltklik + ét tal.

Man kan også starte direkte fra en kommandolinje eller genvej:

    idrac.bat 192.168.1.120 root calvin

Laver man en genvej til det, er det ægte "one click" pr. server.

Manuel metode (de gamle filer)
------------------------------
start_promt.bat og start_quick.bat er den gamle manuelle metode og kræver
at Java ligger i C:\jre og at avctKVM.jar er hentet manuelt - se git-
historikken for den gamle vejledning. Brug idrac.bat i stedet.

Opret en sag hvis du har problemer.
