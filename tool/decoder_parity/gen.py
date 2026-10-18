# Decoder parity test input: clicks at exactly 1000/2000/3000 ms, encoded as
# LAME CBR, LAME VBR, MP3 without Xing/LAME header, and Vorbis. Needs ffmpeg.
import wave, struct, subprocess, sys
sr=44100; n=sr*5
clicks=[sr*1, sr*2, sr*3]   # exactly 1000/2000/3000 ms
buf=[0.0]*n
for c in clicks:
    for k in range(40): buf[c+k]=0.9*(1-k/40)*(1 if k%2==0 else -1)
with wave.open('src.wav','wb') as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(sr)
    w.writeframes(b''.join(struct.pack('<hh',int(v*32767),int(v*32767)) for v in buf))
ff=['ffmpeg','-y','-loglevel','error','-i','src.wav']
subprocess.run(ff+['-c:a','libmp3lame','-b:a','192k','cbr.mp3'],check=True)
subprocess.run(ff+['-c:a','libmp3lame','-q:a','2','vbr.mp3'],check=True)
subprocess.run(ff+['-c:a','libmp3lame','-b:a','192k','-write_xing','0','noxing.mp3'],check=True)
subprocess.run(ff+['-c:a','libvorbis','-q:a','5','vorbis.ogg'],check=True)
