"""Coppa Élite card layout matching Overlay.swift: Archivo, navy, gold, name then surname."""
import math
from PIL import Image,ImageDraw,ImageFont
from captions import font_path


def card(title,size):
    w,h=size; k=min(w,h)/1080*float(title.get('size',1))
    canvas=Image.new('RGBA',size); draw=ImageDraw.Draw(canvas)
    if title.get('style')=='text':
        text=title.get('names','Il tuo testo')
        if isinstance(text,list): text='\n'.join(text)
        f=ImageFont.truetype(font_path('ArchivoBlack'),max(1,round(64*k)))
        draw.multiline_text((float(title.get('x',.08))*w,float(title.get('y',.45))*h),text,font=f,fill='white',
                            stroke_width=max(1,round(3*k)),stroke_fill=(0,0,0,220),spacing=max(1,round(12*k)))
        return canvas
    names=title.get('names','Nome Cognome')
    if isinstance(names,list): names='\n'.join(names)
    names=[s.strip().upper().split(maxsplit=1) for s in names.splitlines() if s.strip()]
    parts=[('',n[0]) if len(n)==1 else (n[0],n[1]) for n in names]
    def font(name,px): return ImageFont.truetype(font_path(name),max(1,round(px)))
    def width(text,f,tracking): return sum(f.getlength(c) for c in text)+tracking*max(0,len(text)-1)
    def tracked(text,x,y,f,fill,tracking):
        for letter in text:
            draw.text((x,y),letter,font=f,fill=fill,anchor='ls'); x+=f.getlength(letter)+tracking
        return x
    fs=60 if len(names)==1 else 46
    while True:
        surname=font('ArchivoBlack',fs*k); first=font('Archivo800',fs*k)
        tw=max([width(a,first,k)+(22*k if a and b else 0)+width(b,surname,k) for a,b in parts] or [0])
        if tw<=780*k or fs<=30: break
        fs-=2
    label=title.get('label','COPPA ÉLITE  /  WINTER EDITION'); show_label=bool(title.get('showLabel',True) and label)
    label_font=font('Archivo800',20*k); label_width=width(label,label_font,6*k) if show_label else 0
    padx=36*k; line_h=fs*1.28*k; top=(22 if show_label else 18)*k
    card_h=top+(40*k if show_label else 0)+line_h*len(names)+20*k; card_w=padx*2+max(tw,label_width)
    x=float(title.get('x',60/1080))*w; y=float(title.get('y',1330/1920))*h
    if names:
        draw.rectangle((x,y,x+card_w,y+card_h),fill=(9,26,46,224))
        draw.rectangle((x+k,y+k,x+card_w-k,y+card_h-k),outline=(255,255,255,96),width=max(1,round(2*k)))
        if show_label: tracked(label,x+padx,y+top+16*k,label_font,'#ffd23f',6*k)
        text_y=y+top+(40*k if show_label else 0)
        cap_h=surname.getbbox('H')[3]-surname.getbbox('H')[1]
        for a,b in parts:
            baseline=text_y+(line_h+cap_h)/2; text_x=x+padx
            if a: text_x=tracked(a,text_x,baseline,first,(255,255,255,235),k)+22*k
            if b: tracked(b,text_x,baseline,surname,'white',k)
            text_y+=line_h
    tag=title.get('tag','MVP').strip().upper()
    if tag:
        tf=font('ArchivoBlack',46*k); tag_w=76*k+width(tag,tf,8*k); tag_y=y+card_h+10*k if names else y
        draw.rectangle((x,tag_y,x+tag_w,tag_y+76*k),fill='#ffd23f')
        cap_h=tf.getbbox('H')[3]-tf.getbbox('H')[1]
        tracked(tag,x+38*k,tag_y+(76*k+cap_h)/2,tf,'#0b1626',8*k)
    return canvas
