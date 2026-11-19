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


def change_speed(project,c,speed):
    from captions import retime
    end=c['start']+c['duration']; duration=c['duration']*c.get('speed',1)/speed; delta=duration-c['duration']
    for other in project.clips:
        if other is not c and other['start']>=end-1e-6: other['start']+=delta
    for caption in project.data.get('captions',[]):
        if caption['start']>=end-1e-6: retime(caption,caption['start']+delta,caption['end']+delta)
    c.update(speed=speed,duration=duration)
