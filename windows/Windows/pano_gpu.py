"""Optional OpenCL version of the calibrated fisheye shader (CPU fallback in pano.py)."""
import threading
import numpy as np

SOURCE=r'''
float3 readpix(__global const uchar *p,int w,int h,int x,int y) {
    int i=(clamp(y,0,h-1)*w+clamp(x,0,w-1))*3;
    return (float3)(p[i],p[i+1],p[i+2]);
}
float3 sample(__global const uchar *p,int w,int h,float2 uv) {
    uv=clamp(uv,(float2)(0.f),(float2)(w-1.f,h-1.f));
    int x=(int)floor(uv.x), y=(int)floor(uv.y); float2 f=uv-(float2)(x,y);
    return mix(mix(readpix(p,w,h,x,y),readpix(p,w,h,x+1,y),f.x),mix(readpix(p,w,h,x,y+1),readpix(p,w,h,x+1,y+1),f.x),f.y);
}
float3 lens(__global const uchar *p,int w,int h,__constant float *u,int b,float3 d,float *weight) {
    float3 l=(float3)(u[b+4]*d.x+u[b+7]*d.y+u[b+10]*d.z,u[b+5]*d.x+u[b+8]*d.y+u[b+11]*d.z,u[b+6]*d.x+u[b+9]*d.y+u[b+12]*d.z);
    float theta=acos(clamp(l.z,-1.f,1.f))*57.29577951f;
    *weight=clamp((93.f-theta)/6.f,0.f,1.f);
    if (*weight<=0) return (float3)(0.f);
    float poly=u[12]+theta*(u[13]+theta*(u[14]+theta*(u[15]+theta*u[16])));
    float rho=u[b+2]*poly/u[17]; float2 n=normalize(l.xy+(float2)(1e-9f,0));
    float a=u[b+3]; float2 rd=(float2)(n.x*cos(a)-n.y*sin(a),n.x*sin(a)+n.y*cos(a));
    return sample(p,w,h,(float2)(u[b]+rho*rd.x,u[b+1]-rho*rd.y));
}
__kernel void pano(__global const uchar *a,int aw,int ah,__global const uchar *b,int bw,int bh,
                   __constant float *u,__global uchar *out,int w,int h) {
    int x=get_global_id(0), y=get_global_id(1); if(x>=w||y>=h) return;
    float2 q=((float2)(x+.5f,y+.5f)/(float2)(w,h))*2.f-1.f;
    float k=u[11]; float3 v=(float3)(q.x*u[9],-q.y*u[10],1.f+k), P=(float3)(0,0,-k);
    float vv=dot(v,v),pv=dot(P,v); float s=(-pv+sqrt(fmax(0.f,pv*pv-vv*(k*k-1.f))))/vv;
    float3 ray=normalize(P+s*v);
    float3 d=(float3)(dot((float3)(u[0],u[1],u[2]),ray),dot((float3)(u[3],u[4],u[5]),ray),dot((float3)(u[6],u[7],u[8]),ray));
    float wa,wb; float3 ca=lens(a,aw,ah,u,18,d,&wa),cb=lens(b,bw,bh,u,31,d,&wb);
    float3 rgb=(ca*wa+cb*wb)/fmax(wa+wb,1e-6f); int i=(y*w+x)*3;
    out[i]=convert_uchar_sat_rte(rgb.x); out[i+1]=convert_uchar_sat_rte(rgb.y); out[i+2]=convert_uchar_sat_rte(rgb.z);
}
'''


class GPU:
    _shared=None
    _unavailable=False
    _setup_lock=threading.Lock()
    @classmethod
    def get(cls):
        with cls._setup_lock:
            if cls._unavailable: return None
            if cls._shared is None:
                try: cls._shared=cls()
                except Exception: cls._unavailable=True
            return cls._shared
    def __init__(self):
        import pyopencl as cl
        self.cl=cl
        devices=[d for p in cl.get_platforms() for d in p.get_devices() if d.type&cl.device_type.GPU]
        if not devices: raise RuntimeError('No OpenCL GPU')
        device=next((d for d in devices if 'NVIDIA' in d.vendor.upper()),devices[0])
        self.name=device.name; self.context=cl.Context([device]); self.queue=cl.CommandQueue(self.context)
        self.program=cl.Program(self.context,SOURCE).build(); self.kernel=cl.Kernel(self.program,'pano')
        self.lock=threading.Lock(); self.buffers={}; self.last={}
    def buffer(self,key,n,flags):
        entry=self.buffers.get(key)
        if entry is None or entry[0]<n:
            entry=(n,self.cl.Buffer(self.context,flags,n)); self.buffers[key]=entry
            self.last.pop(key,None)
        return entry[1]
    def render(self,frames,data,matrix,view,width,height):
        cl=self.cl
        k=max(0,min(1.5,view['distance'])); half=np.deg2rad(max(5,min(350,view['fov']))/2)
        xmax=(k+1)*np.sin(half)/max(.02,k+np.cos(half))
        values=list(matrix.ravel())+[xmax,xmax*height/width,k]+list(data.poly)+[np.polynomial.polynomial.polyval(100,data.poly)]
        for lens in data.lenses:
            values+=[lens['cx']+lens['xoffset'],lens['cy'],lens['r100'],np.deg2rad(lens['alpha'])]+list(lens['rotation'].ravel())
        uniforms=np.array(values,dtype=np.float32)
        with self.lock:
            sources=[]
            for i,frame in enumerate(frames):
                frame=np.ascontiguousarray(frame); key=f'source{i}'; buf=self.buffer(key,frame.nbytes,cl.mem_flags.READ_ONLY)
                if self.last.get(key) is not frame:
                    cl.enqueue_copy(self.queue,buf,frame,is_blocking=False); self.last[key]=frame
                sources.append(buf)
            ubuf=self.buffer('uniform',uniforms.nbytes,cl.mem_flags.READ_ONLY); cl.enqueue_copy(self.queue,ubuf,uniforms,is_blocking=False)
            image=np.empty((height,width,3),dtype=np.uint8); obuf=self.buffer('output',image.nbytes,cl.mem_flags.WRITE_ONLY)
            ah,aw=frames[0].shape[:2]; bh,bw=frames[1].shape[:2]
            self.kernel(self.queue,((width+15)//16*16,(height+15)//16*16),(16,16),sources[0],np.int32(aw),np.int32(ah),sources[1],np.int32(bw),np.int32(bh),ubuf,obuf,np.int32(width),np.int32(height))
            cl.enqueue_copy(self.queue,image,obuf,is_blocking=True)
        return image
