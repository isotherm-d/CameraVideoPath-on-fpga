import argparse,struct,zlib
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument("--output",type=Path,required=True)
p.add_argument('--filename',default='net_packets.hex')
a=p.parse_args()
count=0
for line in (a.output/a.filename).read_text().splitlines():
    packet=bytes.fromhex(line)
    assert packet[:8]==b"\x55"*7+b"\xd5"
    ethernet=packet[8:]
    assert zlib.crc32(ethernet[:-4])==int.from_bytes(ethernet[-4:],"little"),"Ethernet CRC mismatch"
    ip=ethernet[14:34];words=struct.unpack(">10H",ip);total=sum(words)
    while total>>16:total=(total&65535)+(total>>16)
    assert total==65535,"IPv4 checksum mismatch"
    udp=ethernet[34:42];port=int.from_bytes(udp[2:4],"big")
    fmt=ethernet[43]
    assert port==(6002 if fmt==0x26 else 6000)
    count+=1
assert count==13
print("PASS independent Ethernet CRC, IPv4 checksum and UDP port verification")
