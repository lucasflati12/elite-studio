"""Insta360 trailer, calibrated dual-fisheye reframing and gyro stabilization.
Ported from Sources/EliteStudio/Pano.swift and the Metal compositor.
Coordinates: x right, y up, z along the first lens optical axis.
"""
from __future__ import annotations
import math
from pathlib import Path
import struct
import subprocess
import threading
import numpy as np
import cv2
from scipy.spatial.transform import Rotation, Slerp

MAGIC=b'8db42d694ccc418790edff439fe026bf'
POLY={33:[0,.024134,-7.4557e-5,2.0846e-6,-1.4576e-8],
      38:[0,.024336,-7.55532e-5,2.13171e-6,-1.5040305e-8],
      40:[0,.0259398,-7.3377467e-5,2.2925e-6,-1.7776969e-8]}
DEFAULT_VIEW=dict(yaw=0.,pitch=0.,roll=0.,fov=100.,distance=0.)


def companion(path):
    path=Path(path)
    if '_00_' not in path.name: return None
    other=path.with_name(path.name.replace('_00_','_10_'))
    return other if other.is_file() else None


def primary(path):
    path=Path(path)
    if path.suffix.lower()=='.insv' and '_10_' in path.name:
        other=path.with_name(path.name.replace('_10_','_00_'))
        if other.is_file(): return other
    return path


def secondary(path):
    path=Path(path)
    return path.suffix.lower()=='.insv' and (path.name.upper().startswith('LRV_') or primary(path)!=path)


def records(path):
    with Path(path).open('rb') as f:
        f.seek(0,2); size=f.tell()
        if size<=72: raise ValueError('Insta360 file is too short')
        f.seek(-72,2); footer=f.read(72)
        if footer[40:]!=MAGIC: raise ValueError('Insta360 metadata trailer was not found; this file may have been repaired or stripped of camera metadata')
        length=struct.unpack_from('<I',footer,32)[0]
        if not 72<length<size or length>512*1024*1024: raise ValueError('Invalid Insta360 metadata trailer length')
        f.seek(size-length); data=f.read(length)
    end=len(data)-72; result={}
    while end>6:
        kind,length=struct.unpack_from('<HI',data,end-6)
        start=end-6-length
        if start<0: raise ValueError('Damaged Insta360 metadata record')
        result[kind]=data[start:end-6]; end=start
    return result


class Proto:
    def __init__(self,data):
        self.fields={}; i=0
        def varint():
            nonlocal i
            result=0
            for shift in range(0,70,7):
                if i>=len(data): raise ValueError('Truncated protobuf')
                b=data[i]; i+=1; result|=(b&127)<<shift
                if b<128: return result
            raise ValueError('Invalid protobuf varint')
        while i<len(data):
            key=varint(); field,wire=key>>3,key&7
            if wire==0: value=varint()
            elif wire in (1,5):
                n=8 if wire==1 else 4
                if i+n>len(data): raise ValueError('Truncated protobuf number')
                value=struct.unpack_from('<d' if wire==1 else '<I',data,i)[0]; i+=n
            elif wire==2:
                n=varint()
                if i+n>len(data): raise ValueError('Truncated protobuf field')
                value=data[i:i+n]; i+=n
            else: break
            self.fields[field]=(wire,value)
    def get(self,field,default=None): return self.fields.get(field,(None,default))[1]
    def string(self,field,default=''):
        value=self.get(field,b'')
        return value.decode('utf-8',errors='replace') if isinstance(value,bytes) else default


def rot(axis,degrees): return Rotation.from_rotvec(np.eye(3)[axis]*math.radians(degrees)).as_matrix()


def view_at(reframe,t):
    keys=sorted(reframe.get('keys',[]),key=lambda k:k['t'])
    if not keys: return DEFAULT_VIEW|{k:float(reframe.get(k,v)) for k,v in DEFAULT_VIEW.items()}
    if t<=keys[0]['t']: return DEFAULT_VIEW|keys[0]['view']
    if t>=keys[-1]['t']: return DEFAULT_VIEW|keys[-1]['view']
    right=next(i for i,k in enumerate(keys) if k['t']>t); a,b=keys[right-1],keys[right]
    f=(t-a['t'])/max(1e-6,b['t']-a['t']); f=f*f*(3-2*f)
    return {k:float(a['view'].get(k,v))+(float(b['view'].get(k,v))-float(a['view'].get(k,v)))*f for k,v in DEFAULT_VIEW.items()}


def blur3(values,width):
    a=np.asarray(values,dtype=np.float64); radius=max(1,int(width)//2)
    for _ in range(3):
        prefix=np.concatenate([np.zeros((1,3)),np.cumsum(a,axis=0)])
        lo=np.maximum(0,np.arange(len(a))-radius); hi=np.minimum(len(a),np.arange(len(a))+radius+1)
        a=(prefix[hi]-prefix[lo])/(hi-lo)[:,None]
    return a


class PanoData:
    def __init__(self,path,width,height):
        self.path=primary(path); self.width=width; self.height=height
        rec=records(self.path)
        if 0x101 not in rec: raise ValueError('Camera calibration metadata is missing')
        info=Proto(rec[0x101]); self.camera=info.string(2,'Insta360')
        self.pair=width<height*1.5; self.other=companion(self.path) if self.pair else None
        if self.pair and not self.other: raise FileNotFoundError(f'The second lens is missing. Put the matching _10_ file next to {self.path.name}. Both lenses are decoded automatically.')
        lens_size=width if self.pair else height
        self.poly=np.array([0,1,0,0,0],dtype=np.float64); self.lenses=[]; self.tables={}; self.lock=threading.Lock()
        try: offset=[float(v) for v in info.string(5).split('_')]
        except ValueError: offset=[]
        if len(offset)>=16 and offset[0]==2:
            calib_w=offset[13]; flags=int(offset[15]); crop=Proto(info.get(27,b''))
            src,dst=float(crop.get(1,3040)),float(crop.get(3,2880)); scale=lens_size/max(1,dst)
            for i in range(2):
                r,cx,cy,yaw,pitch,roll=offset[1+i*6:7+i*6]
                cx-=i*calib_w/2
                self.lenses.append(dict(cx=(cx-(src-dst)/2)*scale,cy=(cy-(src-dst)/2)*scale,r100=r*scale,
                    alpha=90+roll+180 if i==0 else -90+roll,
                    rotation=(np.eye(3) if i==0 else rot(1,180))@rot(1,-yaw)@rot(0,pitch),
                    xoffset=lens_size if not self.pair and i==1 else 0))
            self.poly=np.array(POLY.get(flags&255,[0,1,0,0,0]),dtype=np.float64)
        else:
            for i in range(2):
                self.lenses.append(dict(cx=lens_size/2,cy=lens_size/2,r100=lens_size/2*.975,
                    alpha=90 if i==0 else -90,rotation=np.eye(3) if i==0 else rot(1,180),xoffset=lens_size if not self.pair and i==1 else 0))
        self.t=np.empty(0); self.gyro=np.empty((0,3)); self.acc=np.empty((0,3))
        if 0x300 in rec:
            raw=bool(info.get(62,0)); cfg=Proto(info.get(65,b'')); step=20 if raw else 56
            dt=np.dtype([('stamp','<u8'),('v','<u2' if raw else '<f8',(6,))])
            items=np.frombuffer(rec[0x300][:len(rec[0x300])//step*step],dtype=dt)
            vals=items['v'].astype(np.float64)
            if raw:
                vals-=32768; vals[:,:3]*=float(cfg.get(1,16))/32768
                vals[:,3:]*=float(cfg.get(2,2000))/32768*np.pi/180
            self.t=(items['stamp'].astype(np.float64)-float(info.get(24,0)))/(1e6 if raw else 1e3)
            if info.get(29,0): self.t-=float(info.get(28,0))/1000
            self.acc=vals[:,[2,0,1]]*np.array([1,-1,-1]); self.gyro=vals[:,[5,3,4]]*np.array([1,-1,-1])
            valid=np.isfinite(self.t)&np.isfinite(self.acc).all(axis=1)&np.isfinite(self.gyro).all(axis=1)
            self.t,self.acc,self.gyro=self.t[valid],self.acc[valid],self.gyro[valid]
            order=np.argsort(self.t); self.t,self.acc,self.gyro=self.t[order],self.acc[order],self.gyro[order]
            unique=np.r_[True,np.diff(self.t)>1e-7] if len(self.t) else []
            self.t,self.acc,self.gyro=self.t[unique],self.acc[unique],self.gyro[unique]

    def stabilization_table(self,lock_direction,smooth):
        key=(bool(lock_direction),round(float(smooth),3))
        with self.lock:
            if key in self.tables: return self.tables[key]
            if len(self.t)<=10: return None
            n=len(self.t); quats=np.empty((n,4)); q=Rotation.identity(); quats[0]=q.as_quat()
            for i in range(1,n):
                dt=min(.05,max(0,self.t[i]-self.t[i-1])); omega=(self.gyro[i]+self.gyro[i-1])*.5
                q=q*Rotation.from_rotvec(omega*dt); quats[i]=q.as_quat()
            rate=200.; grid=self.t[0]+np.arange(max(2,int((self.t[-1]-self.t[0])*rate)+1))/rate
            grid=np.minimum(grid,self.t[-1]); gq=Slerp(self.t,Rotation.from_quat(quats))(grid)
            acc=np.column_stack([np.interp(grid,self.t,self.acc[:,k]) for k in range(3)])
            ups=blur3(gq.apply(-acc),800); lengths=np.linalg.norm(ups,axis=1)
            ups/=np.maximum(lengths[:,None],1e-9); ups[lengths<1e-9]=[0,1,0]
            target=np.array([0.,1.,0.]); quat=np.column_stack([np.cross(ups,target),1+ups@target])
            opposite=ups@target<-.9999; quat[opposite]=[1,0,0,0]
            quat/=np.maximum(np.linalg.norm(quat,axis=1)[:,None],1e-12)
            level=Rotation.from_quat(quat)*gq; forward=level.apply(np.tile([0,0,1.],(len(grid),1))); forward[:,1]=0
            lengths=np.linalg.norm(forward,axis=1); heading=forward/np.maximum(lengths[:,None],1e-9)
            for i in np.flatnonzero(lengths<1e-6): heading[i]=heading[i-1] if i else [0,0,1]
            hs=blur3(heading,max(1,int(max(.05,smooth)*400))); yaw=np.arctan2(hs[:,0],hs[:,2])
            if lock_direction: yaw[:]=yaw[min(len(yaw)-1,max(0,int(-self.t[0]*rate)))]
            baseline=Rotation.from_rotvec(np.column_stack([np.zeros(len(yaw)),yaw,np.zeros(len(yaw))]))
            out=level.inv()*baseline
            table=(grid,Slerp(grid,out))
            self.tables[key]=table
            return table

    def stabilization(self,t,reframe):
        if not reframe.get('stabilize',True): return np.eye(3)
        table=self.stabilization_table(reframe.get('lockDirection',False),float(reframe.get('smooth',1)))
        if table is None: return np.eye(3)
        grid,slerp=table
        return slerp([np.clip(t,grid[0],grid[-1])]).as_matrix()[0]


class PanoRenderer:
    def __init__(self,path):
        self.path=primary(path); self.cap=cv2.VideoCapture(str(self.path))
        if not self.cap.isOpened(): raise ValueError(f'Cannot decode {self.path.name}')
        w,h=int(self.cap.get(cv2.CAP_PROP_FRAME_WIDTH)),int(self.cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        try: self.data=PanoData(self.path,w,h)
        except Exception:
            self.cap.release(); raise
        self.second=cv2.VideoCapture(str(self.data.other)) if self.data.other else None
        if self.second is not None and not self.second.isOpened(): self.close(); raise ValueError('Cannot decode the second lens')
        self.last={}; self.grids={}

    def close(self):
        self.cap.release()
        if getattr(self,'second',None) is not None: self.second.release()

    def read(self,cap,t):
        key=id(cap); fps=cap.get(cv2.CAP_PROP_FPS) or 30; index=round(max(0,t)*fps)
        if key in self.last and self.last[key][0]==index: return self.last[key][1]
        position=round(cap.get(cv2.CAP_PROP_POS_FRAMES))
        if 0<=index-position<30:
            for _ in range(index-position): cap.grab()
        elif position!=index: cap.set(cv2.CAP_PROP_POS_MSEC,max(0,t)*1000)
        ok,frame=cap.read()
        if not ok: raise ValueError(f'Cannot decode the 360 lens at {t:.3f}s')
        self.last[key]=(index,frame); return frame

    def render(self,t,width,height,reframe=None,use_gpu=True):
        r=reframe or {}; v=view_at(r,t)
        if use_gpu:
            from pano_gpu import GPU
            gpu=GPU.get()
            if gpu is not None:
                matrix=self.data.stabilization(t,r)@rot(1,v['yaw'])@rot(0,-v['pitch'])@rot(2,-v['roll'])
                first=self.read(self.cap,t); second=self.read(self.second,t) if self.second is not None else first
                return gpu.render([first,second],self.data,matrix,v,width,height)
        key=(width,height,round(v['fov'],5),round(v['distance'],5))
        if key not in self.grids:
            k=max(0,min(1.5,v['distance'])); half=np.deg2rad(max(5,min(350,v['fov']))/2)
            xmax=(k+1)*np.sin(half)/max(.02,k+np.cos(half)); ymax=xmax*height/width
            x,y=np.meshgrid((np.arange(width,dtype=np.float32)+.5)/width*2-1,(np.arange(height,dtype=np.float32)+.5)/height*2-1)
            rays=np.stack([x*xmax,-y*ymax,np.full_like(x,1+k)],axis=-1)
            vv=np.sum(rays*rays,axis=-1); pv=-k*rays[:,:,2]
            distance=(-pv+np.sqrt(np.maximum(0,pv*pv-vv*(k*k-1))))/vv
            direction=rays*distance[:,:,None]; direction[:,:,2]-=k
            direction/=np.maximum(np.linalg.norm(direction,axis=-1)[:,:,None],1e-9)
            self.grids[key]=direction.reshape(-1,3)
            if len(self.grids)>8: self.grids.pop(next(iter(self.grids)))
        matrix=self.data.stabilization(t,r)@rot(1,v['yaw'])@rot(0,-v['pitch'])@rot(2,-v['roll'])
        directions=self.grids[key]@matrix.T
        frames=[self.read(self.cap,t),self.read(self.second,t) if self.second is not None else None]
        if frames[1] is None: frames[1]=frames[0]
        output=np.zeros((height,width,3),dtype=np.float32); total=np.zeros((height,width),dtype=np.float32)
        denominator=np.polynomial.polynomial.polyval(100,self.data.poly)
        for i,lens in enumerate(self.data.lenses):
            local=directions@lens['rotation']; th=np.rad2deg(np.arccos(np.clip(local[:,2],-1,1)))
            weight=np.clip((93-th)/6,0,1).reshape(height,width).astype(np.float32)
            rho=lens['r100']*np.polynomial.polynomial.polyval(th,self.data.poly)/denominator
            xy=local[:,:2].copy(); xy[:,0]+=1e-9; xy/=np.maximum(np.linalg.norm(xy,axis=1)[:,None],1e-9)
            a=np.deg2rad(lens['alpha']); dx=xy[:,0]*np.cos(a)-xy[:,1]*np.sin(a); dy=xy[:,0]*np.sin(a)+xy[:,1]*np.cos(a)
            mapx=(lens['cx']+lens['xoffset']+rho*dx).reshape(height,width).astype(np.float32)
            mapy=(lens['cy']-rho*dy).reshape(height,width).astype(np.float32)
            sample=cv2.remap(frames[i],mapx,mapy,cv2.INTER_LINEAR,borderMode=cv2.BORDER_REPLICATE)
            output+=sample.astype(np.float32)*weight[:,:,None]; total+=weight
        output/=np.maximum(total[:,:,None],1e-6)
        return np.clip(output,0,255).astype(np.uint8)


def render_clip(media,clip,path,size,fps,tool,flags,progress=lambda x:None,cancel=None):
    renderer=PanoRenderer(media['path']); w,h=size
    frames=max(1,math.ceil(clip['duration']*fps)); speed=float(clip.get('speed',1)); start=float(clip.get('in',0))
    args=[tool('ffmpeg'),'-hide_banner','-loglevel','error','-y','-f','rawvideo','-pix_fmt','bgr24',
          '-s',f'{w}x{h}','-r',str(fps),'-i','pipe:0']
    if media.get('hasAudio'):
        from core import atempo
        args+=['-ss',str(start),'-t',str(clip['duration']*speed),'-i',media['path'],'-map','0:v','-map','1:a:0',
               '-af',atempo(speed),'-c:a','aac','-b:a','192k']
    args+=['-t',str(clip['duration']),'-c:v','libx264','-preset','fast','-crf','18','-pix_fmt','yuv420p',str(path)]
    logfile=Path(path).with_suffix('.log')
    try:
        with logfile.open('w+',encoding='utf-8') as err:
            proc=subprocess.Popen(args,stdin=subprocess.PIPE,stderr=err,creationflags=flags)
            try:
                for i in range(frames):
                    if cancel is not None and cancel.is_set(): raise RuntimeError('Export cancelled')
                    frame=renderer.render(start+i/fps*speed,w,h,clip.get('pano',{}))
                    proc.stdin.write(frame.tobytes()); progress((i+1)/frames)
                proc.stdin.close()
                if proc.wait():
                    err.seek(0); raise RuntimeError('360 encoding failed:\n'+err.read()[-4000:])
            except BrokenPipeError:
                err.seek(0); raise RuntimeError('360 encoding failed:\n'+err.read()[-4000:])
            finally:
                if proc.poll() is None: proc.terminate(); proc.wait()
    finally: renderer.close()
