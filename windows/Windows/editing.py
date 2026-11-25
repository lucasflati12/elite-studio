"""Timeline operations shared by mouse, keyboard and integration tests."""
import copy


def extract(project,start,end):
    from core import uid
    from captions import extract as extract_captions
    if end-start<=1e-6: return
    out=[]
    for c in project.clips:
        a,b=c['start'],c['start']+c['duration']
        if b<=start: out.append(c)
        elif a>=end: c['start']-=end-start; out.append(c)
        else:
            if a<start:
                left=copy.deepcopy(c); left['duration']=start-a; out.append(left)
            if b>end:
                right=copy.deepcopy(c); right.update(id=uid(),start=start,duration=b-end)
                right['in']=c.get('in',0)+(end-a)*c.get('speed',1); out.append(right)
    project.data['clips']=out
    project.data['captions']=extract_captions(project.data.get('captions',[]),start,end)


def change_speed(project,c,speed,ripple=True):
    from captions import retime
    end=c['start']+c['duration']; duration=c['duration']*c.get('speed',1)/speed; delta=duration-c['duration']
    if ripple:
        for other in project.clips:
            if other is not c and other['start']>=end-1e-6: other['start']+=delta
        for caption in project.data.get('captions',[]):
            if caption['start']>=end-1e-6: retime(caption,caption['start']+delta,caption['end']+delta)
    c.update(speed=speed,duration=duration)


def apply_speed_ramp(project,c,speed,preset,ripple=True):
    """Represent a ramp as three ordinary clips with continuous source ranges."""
    from core import uid
    from captions import retime
    curves={'Montagna':[1.8,.6,1.8],'Bullet':[.25,2.5,.25],'Ingresso veloce':[2,.7,1],'Uscita veloce':[1,.7,2]}
    points=curves[preset]; source_start=c.get('in',0); source_length=c['duration']*c.get('speed',1)
    old_end=c['start']+c['duration']; source_step=source_length/3
    segments=[]; start=c['start']; pos=source_start
    for index,multiplier in enumerate(points):
        source_end=source_start+source_step*(index+1) if index<2 else source_start+source_length
        segment=copy.deepcopy(c)
        segment.update(id=c['id'] if index==0 else uid(),start=start,**{'in':pos},speed=speed*multiplier,duration=(source_end-pos)/(speed*multiplier))
        segment['speedRamp']={'preset':preset,'segment':index,'points':points}
        segments.append(segment); start+=segment['duration']; pos=source_end
    project.data['clips']=[clip for clip in project.clips if clip['id']!=c['id']]+segments
    delta=start-old_end
    if ripple:
        for other in project.clips:
            if other['id'] not in {part['id'] for part in segments} and other['start']>=old_end-1e-6:other['start']+=delta
        for caption in project.data.get('captions',[]):
            if caption['start']>=old_end-1e-6:retime(caption,caption['start']+delta,caption['end']+delta)
    return segments
