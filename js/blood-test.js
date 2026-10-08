/* Satata X-Ray & ECG Center — Blood Test module
 * Invoice-only service: no stock, sample, result or report handling.
 * Catalog is managed by ADMIN; COUNTER uses the shared ADMIN catalog.
 */
(function(){
  'use strict';

  function btTypes(){
    return Array.isArray(appData?.bloodTestTypes)?appData.bloodTestTypes:[];
  }
  function esc(v){
    return typeof escapeHtml==='function' ? escapeHtml(v) : String(v??'');
  }
  function money(v){
    return typeof formatMoney==='function' ? formatMoney(Number(v||0)) : '৳'+Number(v||0).toLocaleString('en-US');
  }
  function monthKey(d){
    if(typeof getLocalDateKey==='function') return getLocalDateKey(d).slice(0,7);
    const x=new Date(d);
    return x.getFullYear()+'-'+String(x.getMonth()+1).padStart(2,'0');
  }

  function getBloodTestByName(name){
    const n=String(name||'').trim().toLowerCase();
    return btTypes().find(x=>String(x.name||'').trim().toLowerCase()===n && x.active!==false)||null;
  }

  function getCurrentBloodTest(){
    const name=String(document.getElementById('entryXray')?.value||'').trim();
    const qty=Math.max(1,parseInt(document.getElementById('entryQty')?.value,10)||1);
    const test=getBloodTestByName(name);
    if(!test)return null;
    const rate=Number(test.rate ?? test.price ?? 0);
    return {
      id:crypto.randomUUID(),
      exam_type:'blood',
      name:test.name,
      film_size:'BLOOD TEST',
      qty,
      price:rate,
      commission:0,
      amount:qty*rate
    };
  }

  async function loadBloodTestTypes(){
    if(!currentUser||!supabaseClient)return;
    let res;
    if(isAdmin()){
      res=await supabaseClient
        .from('blood_test_types')
        .select('*')
        .eq('user_id',currentUser.id)
        .order('name',{ascending:true});
    }else{
      const q=await supabaseClient.rpc('get_shared_blood_test_types');
      res={data:Array.isArray(q.data)?q.data:[],error:q.error};
    }
    if(res.error){
      console.error('Blood Test types load failed:',res.error);
      appData.bloodTestTypes=[];
      renderBloodTestSetup();
      return;
    }
    appData.bloodTestTypes=res.data||[];
    renderBloodTestSetup();
    renderBloodTestStats();
  }

  function renderBloodTestSetup(){
    const body=document.getElementById('bloodTestTypeList');
    if(!body)return;
    const rows=btTypes();
    body.innerHTML=rows.length?rows.map(x=>
      '<tr><td>'+esc(x.name)+'</td><td>'+money(x.rate ?? x.price)+'</td>'+
      '<td><span class="badge '+(x.active?'badge-paid':'badge-due')+'">'+(x.active?'ACTIVE':'INACTIVE')+'</span></td>'+
      '<td>'+(isAdmin()
        ? '<button class="btn btn-ghost" style="padding:5px 8px" data-id="'+esc(x.id)+'" onclick="editBloodTestType(this.dataset.id)">Edit</button> '+
          '<button class="btn btn-danger" style="padding:5px 8px" data-id="'+esc(x.id)+'" onclick="toggleBloodTestType(this.dataset.id)">'+(x.active?'Deactivate':'Activate')+'</button>'
        : '-')+'</td></tr>'
    ).join(''):'<tr><td colspan="4" style="text-align:center;color:var(--text-light)">No Blood Tests configured yet.</td></tr>';
  }

  async function saveBloodTestType(){
    if(!isAdmin()){alert('Only ADMIN can manage Blood Test prices.');return;}
    const id=document.getElementById('bloodTestTypeId')?.value||'';
    const name=String(document.getElementById('bloodTestTypeName')?.value||'').trim();
    const rate=Math.max(0,parseFloat(document.getElementById('bloodTestTypeRate')?.value)||0);
    if(!name){alert('Blood Test name is required.');return;}
    const duplicate=btTypes().find(x=>String(x.name||'').trim().toLowerCase()===name.toLowerCase()&&String(x.id)!==String(id));
    if(duplicate){alert('This Blood Test already exists.');return;}
    const payload={name,rate,active:true};
    const res=id
      ? await supabaseClient.from('blood_test_types').update(payload).eq('id',id).eq('user_id',currentUser.id)
      : await supabaseClient.from('blood_test_types').insert([{...payload,user_id:currentUser.id}]);
    if(res.error){alert('Blood Test save failed: '+res.error.message);return;}
    clearBloodTestTypeForm();
    await loadBloodTestTypes();
  }

  function editBloodTestType(id){
    const x=btTypes().find(t=>String(t.id)===String(id)); if(!x)return;
    document.getElementById('bloodTestTypeId').value=x.id;
    document.getElementById('bloodTestTypeName').value=x.name||'';
    document.getElementById('bloodTestTypeRate').value=Number(x.rate ?? x.price ?? 0);
    document.getElementById('bloodTestTypeSaveBtn').textContent='💾 Update Blood Test';
    document.getElementById('bloodTestTypeName').focus();
  }

  async function toggleBloodTestType(id){
    if(!isAdmin())return;
    const x=btTypes().find(t=>String(t.id)===String(id)); if(!x)return;
    const res=await supabaseClient.from('blood_test_types')
      .update({active:!x.active}).eq('id',id).eq('user_id',currentUser.id);
    if(res.error){alert('Status update failed: '+res.error.message);return;}
    await loadBloodTestTypes();
  }

  function clearBloodTestTypeForm(){
    const id=document.getElementById('bloodTestTypeId');
    const name=document.getElementById('bloodTestTypeName');
    const rate=document.getElementById('bloodTestTypeRate');
    const btn=document.getElementById('bloodTestTypeSaveBtn');
    if(id)id.value='';
    if(name)name.value='';
    if(rate)rate.value='0';
    if(btn)btn.textContent='➕ Add Blood Test';
  }

  function getBloodRows(){
    const patients=Array.isArray(appData?.patients)?appData.patients:[];
    const rows=[];
    patients.forEach(p=>{
      const items=typeof getPatientServiceItems==='function'
        ? getPatientServiceItems(p)
        : (Array.isArray(p.service_items)?p.service_items:[]);
      // Reports are not Blood Test services and must never affect Blood Test
      // statistics. Discount is allocated proportionally across billable
      // invoice services so mixed invoices remain financially accurate.
      const grossAllServices=items.reduce((sum,x)=>{
        const t=String(x?.exam_type||'').trim().toLowerCase();
        if(t==='report') return sum;
        return sum+Number(x.amount||Number(x.qty||1)*Number(x.price||0));
      },0);
      const discount=Math.max(0,Number(p.discount||0));
      const safeGross=Math.max(0,grossAllServices);
      const discountFactor=safeGross>0
        ? Math.max(0,1-(Math.min(discount,safeGross)/safeGross))
        : 1;

      items.filter(x=>{
        const t=String(x?.exam_type||'').trim().toLowerCase();
        return t==='blood'||t==='blood_test'||t==='blood test'||t==='bloodtest';
      }).forEach(x=>{
        const gross=Number(x.amount||Number(x.qty||1)*Number(x.price||0));
        rows.push({
          date:new Date(p.created_at||Date.now()),
          name:String(x.name||'Unknown Test'),
          qty:Math.max(1,Number(x.qty||1)),
          amount:Math.max(0,gross*discountFactor)
        });
      });
    });
    return rows;
  }

  function renderBloodTestStats(){
    const body=document.getElementById('bloodTestStatsBody');
    const summary=document.getElementById('bloodTestStatsSummary');
    if(!body||!summary)return;

    const period=document.getElementById('bloodTestStatsPeriod')?.value||monthKey(new Date());
    const rows=getBloodRows().filter(r=>monthKey(r.date)===period);
    const map=new Map();

    rows.forEach(r=>{
      const old=map.get(r.name)||{name:r.name,count:0,amount:0};
      old.count+=r.qty;
      old.amount+=r.amount;
      map.set(r.name,old);
    });

    const list=[...map.values()].sort((a,b)=>b.count-a.count||b.amount-a.amount||a.name.localeCompare(b.name));
    const totalCount=list.reduce((s,x)=>s+x.count,0);
    const totalAmount=list.reduce((s,x)=>s+x.amount,0);

    summary.innerHTML=
      '<div class="summary">'+
      '<div class="item"><div class="val">'+totalCount+'</div><div class="lbl">Blood Tests</div></div>'+
      '<div class="item"><div class="val">'+money(totalAmount)+'</div><div class="lbl">Blood Test Revenue</div></div>'+
      '<div class="item"><div class="val">'+list.length+'</div><div class="lbl">Test Types</div></div>'+
      '</div>';

    body.innerHTML=list.map(x=>
      '<tr><td>'+esc(x.name)+'</td><td class="center">'+x.count+'</td><td class="right">'+money(x.amount)+'</td></tr>'
    ).join('')||'<tr><td colspan="3" style="text-align:center;color:var(--text-light)">No Blood Test entries for this month.</td></tr>';
  }

  function setBloodTestStatsMonth(offset){
    const el=document.getElementById('bloodTestStatsPeriod'); if(!el)return;
    const d=new Date();
    d.setDate(1);
    d.setMonth(d.getMonth()+Number(offset||0));
    el.value=monthKey(d);
    renderBloodTestStats();
  }

  window.loadBloodTestTypes=loadBloodTestTypes;
  window.getBloodTestByName=getBloodTestByName;
  window.getCurrentBloodTest=getCurrentBloodTest;
  window.isBloodTestService=function(s){
    const t=String(s?.exam_type||'').trim().toLowerCase();
    return t==='blood'||t==='blood_test'||t==='blood test'||t==='bloodtest';
  };
  window.renderBloodTestSetup=renderBloodTestSetup;
  window.saveBloodTestType=saveBloodTestType;
  window.editBloodTestType=editBloodTestType;
  window.toggleBloodTestType=toggleBloodTestType;
  window.clearBloodTestTypeForm=clearBloodTestTypeForm;
  window.renderBloodTestStats=renderBloodTestStats;
  window.setBloodTestStatsMonth=setBloodTestStatsMonth;
})();